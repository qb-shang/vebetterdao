import { ethers } from "hardhat"
import { BytesLike } from "ethers"
import { HardhatEthersSigner } from "@nomicfoundation/hardhat-ethers/signers"
import { expect } from "chai"
import { describe, it } from "mocha"
import { getOrDeployContractInstances } from "./helpers"
import { setupSignalingFixture } from "./vebetterpassport/fixture.test"
import { deployProxy } from "../scripts/helpers"
import { XAppReviewManager } from "../typechain-types"

const UPVOTE = 1
const DOWNVOTE = 2
const REPORT = 3

async function setup() {
  const fixture = await setupSignalingFixture()
  const { xAppReviewManager } = await getOrDeployContractInstances({ forceDeploy: false })
  const { veBetterPassport, owner, otherAccounts, appId } = fixture

  // Registering an action is what X2EarnRewardsPool does when it distributes a reward.
  const makeEligible = async (address: string) =>
    veBetterPassport.connect(owner).registerActionForRound(address, appId, 1)

  const reviewer = otherAccounts[2]
  const voter = otherAccounts[3]
  const outsider = otherAccounts[4]
  await makeEligible(reviewer.address)

  return { ...fixture, xAppReviewManager, makeEligible, reviewer, voter, outsider }
}

async function createReview(rm: XAppReviewManager, signer: HardhatEthersSigner, appId: BytesLike) {
  await rm.connect(signer).createReview(appId, "Great app", "Clear rewards and smooth onboarding.")
  return rm.totalReviews()
}

describe("XAppReviewManager - @shard5", function () {
  describe("Deployment", function () {
    it("links VeBetterPassport and sets defaults", async function () {
      const { xAppReviewManager, veBetterPassport } = await setup()
      expect(await xAppReviewManager.veBetterPassport()).to.equal(await veBetterPassport.getAddress())
      expect(await xAppReviewManager.communityScoreMinRatings()).to.equal(20)
      expect(await xAppReviewManager.totalReviews()).to.equal(0)
      expect(await xAppReviewManager.version()).to.equal("4")
    })

    it("cannot be initialized twice", async function () {
      const { xAppReviewManager, owner } = await setup()
      await expect(xAppReviewManager.initialize(owner.address, owner.address)).to.be.reverted
    })

    it("fails closed with PassportNotSet when no passport is linked", async function () {
      const { owner, appId } = await setup()
      const fresh = (await deployProxy("XAppReviewManager", [owner.address, owner.address])) as XAppReviewManager
      await expect(fresh.connect(owner).submitRating(appId, 5)).to.be.revertedWithCustomError(fresh, "PassportNotSet")
      await expect(fresh.connect(owner).createReview(appId, "t", "c")).to.be.revertedWithCustomError(
        fresh,
        "PassportNotSet",
      )
    })
  })

  describe("Eligibility", function () {
    it("rejects users that never received a reward from the app", async function () {
      const { xAppReviewManager, outsider, appId } = await setup()
      await expect(xAppReviewManager.connect(outsider).submitRating(appId, 4))
        .to.be.revertedWithCustomError(xAppReviewManager, "NotEligible")
        .withArgs(appId, outsider.address)
      await expect(xAppReviewManager.connect(outsider).createReview(appId, "t", "c")).to.be.revertedWithCustomError(
        xAppReviewManager,
        "NotEligible",
      )
    })

    it("accepts a user once the passport records an interaction", async function () {
      const { xAppReviewManager, outsider, appId, makeEligible } = await setup()
      await makeEligible(outsider.address)
      await expect(xAppReviewManager.connect(outsider).submitRating(appId, 4)).to.emit(
        xAppReviewManager,
        "RatingSubmitted",
      )
    })
  })

  describe("Ratings", function () {
    it("stores a rating and aggregates stats scaled by 100", async function () {
      const { xAppReviewManager, reviewer, outsider, appId, makeEligible } = await setup()
      await makeEligible(outsider.address)
      await xAppReviewManager.connect(reviewer).submitRating(appId, 5)
      await xAppReviewManager.connect(outsider).submitRating(appId, 2)

      expect(await xAppReviewManager.getUserRating(appId, reviewer.address)).to.equal(5)
      const [count, avg] = await xAppReviewManager.getAppRatingStats(appId)
      expect(count).to.equal(2)
      expect(avg).to.equal(350)
    })

    it("rejects out-of-range ratings", async function () {
      const { xAppReviewManager, reviewer, appId } = await setup()
      await expect(xAppReviewManager.connect(reviewer).submitRating(appId, 0)).to.be.revertedWithCustomError(
        xAppReviewManager,
        "InvalidRating",
      )
      await expect(xAppReviewManager.connect(reviewer).submitRating(appId, 6)).to.be.revertedWithCustomError(
        xAppReviewManager,
        "InvalidRating",
      )
    })

    it("allows one submission per user, then updates via updateRating", async function () {
      const { xAppReviewManager, reviewer, appId } = await setup()
      await xAppReviewManager.connect(reviewer).submitRating(appId, 1)
      await expect(xAppReviewManager.connect(reviewer).submitRating(appId, 3)).to.be.revertedWithCustomError(
        xAppReviewManager,
        "AlreadyRated",
      )

      await expect(xAppReviewManager.connect(reviewer).updateRating(appId, 4))
        .to.emit(xAppReviewManager, "RatingUpdated")
        .withArgs(appId, reviewer.address, 4)
      const [count, avg] = await xAppReviewManager.getAppRatingStats(appId)
      expect(count).to.equal(1)
      expect(avg).to.equal(400)
    })

    it("rejects updateRating from a user who never rated", async function () {
      const { xAppReviewManager, outsider, appId } = await setup()
      await expect(xAppReviewManager.connect(outsider).updateRating(appId, 3)).to.be.revertedWithCustomError(
        xAppReviewManager,
        "UnauthorizedUser",
      )
    })
  })

  describe("Reviews", function () {
    it("creates a review and indexes it by app and author", async function () {
      const { xAppReviewManager, reviewer, appId } = await setup()
      await expect(xAppReviewManager.connect(reviewer).createReview(appId, "Title", "Content"))
        .to.emit(xAppReviewManager, "ReviewCreated")
        .withArgs(1, appId, reviewer.address)

      const review = await xAppReviewManager.getReview(1)
      expect(review.reviewer).to.equal(reviewer.address)
      expect(review.title).to.equal("Title")
      expect(await xAppReviewManager.getAppReviewIds(appId)).to.deep.equal([1n])
      expect(await xAppReviewManager.getUserReviewIds(reviewer.address)).to.deep.equal([1n])
      expect((await xAppReviewManager.getAppReviewStats(appId))[0]).to.equal(1)
    })

    it("enforces title and content length limits", async function () {
      const { xAppReviewManager, reviewer, appId } = await setup()
      await expect(
        xAppReviewManager.connect(reviewer).createReview(appId, "x".repeat(201), "c"),
      ).to.be.revertedWithCustomError(xAppReviewManager, "TitleTooLong")
      await expect(
        xAppReviewManager.connect(reviewer).createReview(appId, "t", "x".repeat(2001)),
      ).to.be.revertedWithCustomError(xAppReviewManager, "ContentTooLong")
      await expect(xAppReviewManager.connect(reviewer).createReview(appId, "x".repeat(200), "x".repeat(2000))).to.not.be
        .reverted
    })

    it("lets only the author edit", async function () {
      const { xAppReviewManager, reviewer, outsider, appId } = await setup()
      const id = await createReview(xAppReviewManager, reviewer, appId)

      await expect(xAppReviewManager.connect(outsider).editReview(id, "t", "c")).to.be.revertedWithCustomError(
        xAppReviewManager,
        "NotReviewAuthor",
      )
      await expect(xAppReviewManager.connect(reviewer).editReview(id, "New", "Body"))
        .to.emit(xAppReviewManager, "ReviewUpdated")
        .withArgs(id)
      expect((await xAppReviewManager.getReview(id)).title).to.equal("New")
    })

    it("reverts for unknown review ids", async function () {
      const { xAppReviewManager, reviewer } = await setup()
      await expect(xAppReviewManager.getReview(99)).to.be.revertedWithCustomError(xAppReviewManager, "ReviewNotFound")
      await expect(xAppReviewManager.connect(reviewer).editReview(99, "t", "c")).to.be.revertedWithCustomError(
        xAppReviewManager,
        "ReviewNotFound",
      )
      await expect(xAppReviewManager.connect(reviewer).voteOnReview(99, UPVOTE)).to.be.revertedWithCustomError(
        xAppReviewManager,
        "ReviewNotFound",
      )
    })
  })

  describe("Votes", function () {
    it("records an upvote and blocks repeating the same vote type", async function () {
      const { xAppReviewManager, reviewer, voter, appId } = await setup()
      const id = await createReview(xAppReviewManager, reviewer, appId)

      await expect(xAppReviewManager.connect(voter).voteOnReview(id, UPVOTE))
        .to.emit(xAppReviewManager, "ReviewVoted")
        .withArgs(id, voter.address, UPVOTE)
      await expect(xAppReviewManager.connect(voter).voteOnReview(id, UPVOTE)).to.be.revertedWithCustomError(
        xAppReviewManager,
        "AlreadyVoted",
      )
      expect((await xAppReviewManager.getReview(id)).upvotes).to.equal(1)
      expect((await xAppReviewManager.getVoteHistory(id)).length).to.equal(1)
    })

    // Documents current behaviour: vote types are independent and final.
    it("lets one voter hold an upvote and a downvote on the same review", async function () {
      const { xAppReviewManager, reviewer, voter, appId } = await setup()
      const id = await createReview(xAppReviewManager, reviewer, appId)

      await xAppReviewManager.connect(voter).voteOnReview(id, UPVOTE)
      await xAppReviewManager.connect(voter).voteOnReview(id, DOWNVOTE)

      const review = await xAppReviewManager.getReview(id)
      expect(review.upvotes).to.equal(1)
      expect(review.downvotes).to.equal(1)
      expect(await xAppReviewManager.getUserVotes(id, voter.address)).to.deep.equal([true, true, false])
    })

    it("rejects self-votes and the NONE vote type", async function () {
      const { xAppReviewManager, reviewer, voter, appId } = await setup()
      const id = await createReview(xAppReviewManager, reviewer, appId)

      await expect(xAppReviewManager.connect(reviewer).voteOnReview(id, UPVOTE)).to.be.revertedWithCustomError(
        xAppReviewManager,
        "CannotVoteOwnReview",
      )
      await expect(xAppReviewManager.connect(voter).voteOnReview(id, 0)).to.be.reverted
    })

    it("does not require voters to be eligible", async function () {
      const { xAppReviewManager, reviewer, outsider, appId } = await setup()
      const id = await createReview(xAppReviewManager, reviewer, appId)
      await expect(xAppReviewManager.connect(outsider).voteOnReview(id, DOWNVOTE)).to.not.be.reverted
    })
  })

  describe("Reports and moderation", function () {
    it("auto-hides a review at 20 reports and blocks further votes", async function () {
      const { xAppReviewManager, reviewer, voter, owner, appId } = await setup()
      const id = await createReview(xAppReviewManager, reviewer, appId)
      const threshold = Number(await xAppReviewManager.AUTO_HIDE_REPORT_THRESHOLD())
      expect(threshold).to.equal(20)

      for (let i = 0; i < threshold - 1; i++) {
        const w = ethers.Wallet.createRandom().connect(ethers.provider)
        await owner.sendTransaction({ to: w.address, value: ethers.parseEther("1") })
        await xAppReviewManager.connect(w).voteOnReview(id, REPORT)
      }
      expect((await xAppReviewManager.getReview(id)).hidden).to.equal(false)

      await expect(xAppReviewManager.connect(voter).voteOnReview(id, REPORT))
        .to.emit(xAppReviewManager, "ReviewHidden")
        .withArgs(id)
      expect((await xAppReviewManager.getReview(id)).hidden).to.equal(true)

      await expect(xAppReviewManager.connect(owner).voteOnReview(id, UPVOTE)).to.be.revertedWithCustomError(
        xAppReviewManager,
        "ReviewIsHidden",
      )
    })

    it("lets a moderator or admin unhide, and nobody else", async function () {
      const { xAppReviewManager, reviewer, owner, outsider, appId, otherAccounts } = await setup()
      const id = await createReview(xAppReviewManager, reviewer, appId)
      const moderator = otherAccounts[5]

      await expect(xAppReviewManager.connect(outsider).unhideReview(id)).to.be.revertedWithCustomError(
        xAppReviewManager,
        "UnauthorizedUser",
      )

      await xAppReviewManager.connect(owner).grantRole(await xAppReviewManager.MODERATOR_ROLE(), moderator.address)
      await expect(xAppReviewManager.connect(moderator).unhideReview(id))
        .to.emit(xAppReviewManager, "ReviewUnhidden")
        .withArgs(id)
      await expect(xAppReviewManager.connect(owner).unhideReview(id)).to.not.be.reverted
    })
  })

  describe("Admin", function () {
    it("restricts setVeBetterPassport to the admin and rejects zero address", async function () {
      const { xAppReviewManager, owner, outsider } = await setup()
      await expect(xAppReviewManager.connect(outsider).setVeBetterPassport(outsider.address)).to.be.reverted
      await expect(xAppReviewManager.connect(owner).setVeBetterPassport(ethers.ZeroAddress)).to.be.revertedWith(
        "XAppReviewManager: veBetterPassport is the zero address",
      )
      await expect(xAppReviewManager.connect(owner).setVeBetterPassport(outsider.address))
        .to.emit(xAppReviewManager, "VeBetterPassportUpdated")
        .withArgs(outsider.address)
    })

    it("restricts setCommunityScoreMinRatings to the admin and rejects zero", async function () {
      const { xAppReviewManager, owner, outsider } = await setup()
      await expect(xAppReviewManager.connect(outsider).setCommunityScoreMinRatings(5)).to.be.reverted
      await expect(xAppReviewManager.connect(owner).setCommunityScoreMinRatings(0)).to.be.revertedWith(
        "XAppReviewManager: minRatings must be positive",
      )
      await expect(xAppReviewManager.connect(owner).setCommunityScoreMinRatings(5))
        .to.emit(xAppReviewManager, "CommunityScoreMinRatingsUpdated")
        .withArgs(5)
      expect(await xAppReviewManager.communityScoreMinRatings()).to.equal(5)
    })

    it("only lets UPGRADER_ROLE upgrade the proxy", async function () {
      const { xAppReviewManager, owner, outsider } = await setup()
      const impl = await (await ethers.getContractFactory("XAppReviewManager")).deploy()
      await impl.waitForDeployment()

      await expect(xAppReviewManager.connect(outsider).upgradeToAndCall(await impl.getAddress(), "0x")).to.be.reverted
      await expect(xAppReviewManager.connect(owner).upgradeToAndCall(await impl.getAddress(), "0x")).to.not.be.reverted
    })
  })
})
