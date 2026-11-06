// SPDX-License-Identifier: MIT

//                                      #######
//                                 ################
//                               ####################
//                             ###########   #########
//                            #########      #########
//          #######          #########       #########
//          #########       #########      ##########
//           ##########     ########     ####################
//            ##########   #########  #########################
//              ################### ############################
//               #################  ##########          ########
//                 ##############      ###              ########
//                  ############                       #########
//                    ##########                     ##########
//                     ########                    ###########
//                       ###                    ############
//                                          ##############
//                                    #################
//                                   ##############
//                                   #########

pragma solidity 0.8.20;

import { AccessControlUpgradeable } from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import { UUPSUpgradeable } from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import { IVeBetterPassport } from "../interfaces/IVeBetterPassport.sol";

/// @title XAppReviewManager
/// @notice Handles user reviews and ratings for X2Earn apps in the VeBetterDAO ecosystem.
/// @dev Upgradeable contract with ERC-7201 namespaced storage. Rating (1-5 stars) and text reviews
/// are independent operations: users can rate without reviewing and vice versa. Each user has at most
/// one rating per app (upsert via submitRating/updateRating). Other users can upvote, downvote,
/// or report reviews. Reviews are auto-hidden after 20 reports.
contract XAppReviewManager is AccessControlUpgradeable, UUPSUpgradeable {
    // ---------------- Roles ----------------
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 public constant MODERATOR_ROLE = keccak256("MODERATOR_ROLE");

    // ---------------- Constants ----------------
    uint8 public constant MIN_RATING = 1;
    uint8 public constant MAX_RATING = 5;
    uint256 public constant MAX_TITLE_LENGTH = 200;
    uint256 public constant MAX_CONTENT_LENGTH = 2000;
    uint256 public constant AUTO_HIDE_REPORT_THRESHOLD = 20;
    uint256 public constant DEFAULT_COMMUNITY_SCORE_MIN_RATINGS = 20;

    // ---------------- Enums ----------------
    enum VoteType {
        NONE,
        UPVOTE,
        DOWNVOTE,
        REPORT
    }

    // ---------------- Structs ----------------
    struct Review {
        uint256 id;
        bytes32 appId;
        address reviewer;
        uint8 rating; // deprecated — kept for storage-layout compatibility
        string title;
        string content;
        uint256 createdAt;
        uint256 updatedAt;
        uint256 upvotes;
        uint256 downvotes;
        uint256 reports;
        bool hidden;
    }

    struct VoteEntry {
        address voter;
        VoteType voteType;
        uint256 timestamp;
    }

    // ---------------- Errors ----------------
    error InvalidRating(uint8 rating);
    error TitleTooLong(uint256 length, uint256 max);
    error ContentTooLong(uint256 length, uint256 max);
    error ReviewNotFound(uint256 reviewId);
    error ReviewIsHidden(uint256 reviewId);
    error NotReviewAuthor(uint256 reviewId, address caller);
    error CannotVoteOwnReview(uint256 reviewId);
    error AlreadyVoted(uint256 reviewId, address voter, VoteType existingVote);
    error UnauthorizedUser(address user);
    error AlreadyRated(bytes32 appId, address rater);
    error NotEligible(bytes32 appId, address user);
    error PassportNotSet();

    // ---------------- Events ----------------
    event ReviewCreated(
        uint256 indexed reviewId,
        bytes32 indexed appId,
        address indexed reviewer
    );
    event ReviewUpdated(uint256 indexed reviewId);
    event ReviewVoted(
        uint256 indexed reviewId,
        address indexed voter,
        VoteType voteType
    );
    event ReviewHidden(uint256 indexed reviewId);
    event ReviewUnhidden(uint256 indexed reviewId);
    event RatingSubmitted(bytes32 indexed appId, address indexed rater, uint8 rating);
    event RatingUpdated(bytes32 indexed appId, address indexed rater, uint8 rating);
    event VeBetterPassportUpdated(IVeBetterPassport indexed passport);
    event CommunityScoreMinRatingsUpdated(uint256 indexed newMinRatings);

    // ---------------- Storage ----------------
    /// @custom:storage-location erc7201:b3tr.storage.XAppReviewManager
    struct XAppReviewManagerStorage {
        uint256 nextReviewId;
        mapping(uint256 => Review) reviews;
        mapping(bytes32 => uint256[]) appReviewIds;
        mapping(address => uint256[]) userReviewIds;
        // reviewId => voter => voteType => cast (a voter may hold up to one of each VoteType)
        mapping(uint256 => mapping(address => mapping(VoteType => bool))) reviewVotes;
        mapping(uint256 => VoteEntry[]) voteHistory;
        mapping(bytes32 => uint256) appReviewCount;
        // appId => sum of all ratings * 100 (for precision, divide by count to get avg)
        mapping(bytes32 => uint256) appRatingSum;
        // appId => rater => rating (1-5), 0 means not rated
        mapping(bytes32 => mapping(address => uint8)) userRatings;
        // appId => number of unique raters
        mapping(bytes32 => uint256) appRatingCount;
        // VeBetterPassport used to verify a user has received rewards from an app
        IVeBetterPassport veBetterPassport;
        // Minimum number of ratings for an app to be eligible for a non-zero Community Score.
        // Governance-adjustable via setCommunityScoreMinRatings.
        uint256 communityScoreMinRatings;
    }

    // NOTE: this value does not equal the ERC-7201 formula for "b3tr.storage.XAppReviewManager"
    // (which gives 0x9dbb2928e56385cf3a222ec1f9ea7136342a4b06a73d9907eafd0ab212380e00).
    // It is kept as-is because deployed proxies already store state at this slot.
    bytes32 private constant XAppReviewManagerStorageLocation =
        0x496a0144db85d0a76089a964a1bb51cc6084a4ba98297bcf893c5b54a1a70300;

    function _getStorage() private pure returns (XAppReviewManagerStorage storage $) {
        assembly {
            $.slot := XAppReviewManagerStorageLocation
        }
    }

    // ---------------- Initialization ----------------

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    /// @notice Initializes the contract with access control.
    /// @param defaultAdmin Address to be assigned the DEFAULT_ADMIN_ROLE.
    /// @param upgrader Address to be assigned the UPGRADER_ROLE.
    function initialize(address defaultAdmin, address upgrader) public initializer {
        require(defaultAdmin != address(0), "XAppReviewManager: zero admin address");
        require(upgrader != address(0), "XAppReviewManager: zero upgrader address");

        __AccessControl_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, defaultAdmin);
        _grantRole(UPGRADER_ROLE, upgrader);

        XAppReviewManagerStorage storage $ = _getStorage();
        $.nextReviewId = 1;
        $.communityScoreMinRatings = DEFAULT_COMMUNITY_SCORE_MIN_RATINGS;
    }

    // ---------------- Modifiers ----------------

    modifier onlyRoleOrAdmin(bytes32 role) {
        if (!hasRole(role, msg.sender) && !hasRole(DEFAULT_ADMIN_ROLE, msg.sender)) {
            revert UnauthorizedUser(msg.sender);
        }
        _;
    }

    // ---------------- UUPS ----------------

    function _authorizeUpgrade(address) internal override onlyRole(UPGRADER_ROLE) {}

    function version() public pure returns (string memory) {
        return "4";
    }

    /// @notice Reverts if the caller has not received a reward from the app.
    /// @dev Eligibility is read from the linked VeBetterPassport, which records a unique
    /// app interaction for a user every time X2EarnRewardsPool distributes a reward to them.
    /// Until [setVeBetterPassport] is called the check fails closed with [PassportNotSet].
    /// @param appId The app the caller wants to rate or review.
    /// @param user The caller address.
    function _requireEligible(bytes32 appId, address user) internal view {
        XAppReviewManagerStorage storage $ = _getStorage();
        if (address($.veBetterPassport) == address(0)) revert PassportNotSet();
        if (!$.veBetterPassport.userUniqueAppInteraction(user, appId)) revert NotEligible(appId, user);
    }

    // ---------------- External: Review CRUD ----------------

    /// @notice Creates a review for an app. Caller must have received rewards from the app;
    /// eligibility is enforced on-chain via VeBetterPassport (see [_requireEligible]).
    /// @param appId The hashed app ID from X2EarnApps.
    /// @param title Review title (max 200 chars).
    /// @param content Review content (max 2000 chars).
    /// @return reviewId The ID of the newly created review.
    function createReview(
        bytes32 appId,
        string calldata title,
        string calldata content
    ) external returns (uint256 reviewId) {
        _requireEligible(appId, msg.sender);
        if (bytes(title).length > MAX_TITLE_LENGTH) revert TitleTooLong(bytes(title).length, MAX_TITLE_LENGTH);
        if (bytes(content).length > MAX_CONTENT_LENGTH) revert ContentTooLong(bytes(content).length, MAX_CONTENT_LENGTH);

        XAppReviewManagerStorage storage $ = _getStorage();
        reviewId = $.nextReviewId++;

        $.reviews[reviewId] = Review({
            id: reviewId,
            appId: appId,
            reviewer: msg.sender,
            rating: 0,
            title: title,
            content: content,
            createdAt: block.timestamp,
            updatedAt: block.timestamp,
            upvotes: 0,
            downvotes: 0,
            reports: 0,
            hidden: false
        });

        $.appReviewIds[appId].push(reviewId);
        $.userReviewIds[msg.sender].push(reviewId);
        $.appReviewCount[appId]++;

        emit ReviewCreated(reviewId, appId, msg.sender);
    }

    /// @notice Edits an existing review. Only the original author can edit.
    /// @param reviewId The ID of the review to edit.
    /// @param title New title (max 200 chars).
    /// @param content New content (max 2000 chars).
    function editReview(
        uint256 reviewId,
        string calldata title,
        string calldata content
    ) external {
        XAppReviewManagerStorage storage $ = _getStorage();
        Review storage review = $.reviews[reviewId];
        if (review.id == 0) revert ReviewNotFound(reviewId);
        if (review.reviewer != msg.sender) revert NotReviewAuthor(reviewId, msg.sender);
        if (bytes(title).length > MAX_TITLE_LENGTH) revert TitleTooLong(bytes(title).length, MAX_TITLE_LENGTH);
        if (bytes(content).length > MAX_CONTENT_LENGTH) revert ContentTooLong(bytes(content).length, MAX_CONTENT_LENGTH);

        review.title = title;
        review.content = content;
        review.updatedAt = block.timestamp;

        emit ReviewUpdated(reviewId);
    }

    // ---------------- External: Rating ----------------

    /// @notice Submits a rating for an app. Each user can rate an app once; subsequent calls revert.
    /// The caller must have received rewards from the app (see [_requireEligible]).
    /// @param appId The hashed app ID from X2EarnApps.
    /// @param rating Star rating (1-5).
    function submitRating(bytes32 appId, uint8 rating) external {
        _requireEligible(appId, msg.sender);
        if (rating < MIN_RATING || rating > MAX_RATING) revert InvalidRating(rating);

        XAppReviewManagerStorage storage $ = _getStorage();
        if ($.userRatings[appId][msg.sender] != 0) revert AlreadyRated(appId, msg.sender);

        $.userRatings[appId][msg.sender] = rating;
        $.appRatingCount[appId]++;
        $.appRatingSum[appId] += uint256(rating) * 100;

        emit RatingSubmitted(appId, msg.sender, rating);
    }

    /// @notice Updates an existing rating for an app.
    /// @param appId The hashed app ID from X2EarnApps.
    /// @param rating New star rating (1-5).
    function updateRating(bytes32 appId, uint8 rating) external {
        if (rating < MIN_RATING || rating > MAX_RATING) revert InvalidRating(rating);

        XAppReviewManagerStorage storage $ = _getStorage();
        uint8 previous = $.userRatings[appId][msg.sender];
        if (previous == 0) revert UnauthorizedUser(msg.sender);

        $.appRatingSum[appId] = $.appRatingSum[appId] - uint256(previous) * 100 + uint256(rating) * 100;
        $.userRatings[appId][msg.sender] = rating;

        emit RatingUpdated(appId, msg.sender, rating);
    }

    // ---------------- External: Voting ----------------

    /// @notice Votes on a review (upvote, downvote, or report). Cannot vote on own review.
    /// A voter may hold up to one of each VoteType on the same review (all three are independent).
    /// Votes cannot be cancelled: casting a VoteType already held reverts with [AlreadyVoted].
    /// @param reviewId The ID of the review to vote on.
    /// @param voteType The type of vote (UPVOTE, DOWNVOTE, or REPORT).
    function voteOnReview(uint256 reviewId, VoteType voteType) external {
        if (voteType == VoteType.NONE) revert(); // must pick a valid vote type

        XAppReviewManagerStorage storage $ = _getStorage();
        Review storage review = $.reviews[reviewId];
        if (review.id == 0) revert ReviewNotFound(reviewId);
        if (review.hidden) revert ReviewIsHidden(reviewId);
        if (review.reviewer == msg.sender) revert CannotVoteOwnReview(reviewId);

        // Each VoteType is independent and can only be cast once per (review, voter).
        if ($.reviewVotes[reviewId][msg.sender][voteType]) {
            revert AlreadyVoted(reviewId, msg.sender, voteType);
        }

        // Record the vote (no removal of other types — votes are not cancellable).
        $.reviewVotes[reviewId][msg.sender][voteType] = true;
        $.voteHistory[reviewId].push(VoteEntry({
            voter: msg.sender,
            voteType: voteType,
            timestamp: block.timestamp
        }));

        if (voteType == VoteType.UPVOTE) {
            review.upvotes++;
        } else if (voteType == VoteType.DOWNVOTE) {
            review.downvotes++;
        } else if (voteType == VoteType.REPORT) {
            review.reports++;
            if (review.reports >= AUTO_HIDE_REPORT_THRESHOLD) {
                review.hidden = true;
                emit ReviewHidden(reviewId);
            }
        }

        emit ReviewVoted(reviewId, msg.sender, voteType);
    }

    // ---------------- External: Moderation ----------------

    /// @notice Unhides a review that was auto-hidden due to reports.
    /// @param reviewId The ID of the review to unhide.
    function unhideReview(uint256 reviewId) external onlyRoleOrAdmin(MODERATOR_ROLE) {
        XAppReviewManagerStorage storage $ = _getStorage();
        Review storage review = $.reviews[reviewId];
        if (review.id == 0) revert ReviewNotFound(reviewId);
        review.hidden = false;
        emit ReviewUnhidden(reviewId);
    }

    // ---------------- Configuration ----------------

    /// @notice Sets the VeBetterPassport used for reward-eligibility checks.
    /// @dev Must be called right after an upgrade; otherwise rating and review creation
    /// revert with [PassportNotSet] for everyone.
    /// @param _veBetterPassport The VeBetterPassport contract address.
    function setVeBetterPassport(IVeBetterPassport _veBetterPassport) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(
            address(_veBetterPassport) != address(0),
            "XAppReviewManager: veBetterPassport is the zero address"
        );
        _getStorage().veBetterPassport = _veBetterPassport;
        emit VeBetterPassportUpdated(_veBetterPassport);
    }

    /// @notice Returns the VeBetterPassport used for eligibility checks.
    function veBetterPassport() external view returns (IVeBetterPassport) {
        return _getStorage().veBetterPassport;
    }

    /// @notice Sets the minimum number of ratings required for a non-zero Community Score.
    /// @dev Governance-adjustable. Must be > 0. Defaults to 20 on fresh deploys; existing
    /// deployments are seeded to 20 by the v4 upgrade script.
    /// @param _minRatings The new minimum ratings threshold.
    function setCommunityScoreMinRatings(uint256 _minRatings) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_minRatings > 0, "XAppReviewManager: minRatings must be positive");
        _getStorage().communityScoreMinRatings = _minRatings;
        emit CommunityScoreMinRatingsUpdated(_minRatings);
    }

    /// @notice Returns the minimum number of ratings required for a non-zero Community Score.
    function communityScoreMinRatings() external view returns (uint256) {
        return _getStorage().communityScoreMinRatings;
    }

    // ---------------- Getters ----------------

    /// @notice Returns a single review by ID.
    function getReview(uint256 reviewId) external view returns (Review memory) {
        XAppReviewManagerStorage storage $ = _getStorage();
        Review memory review = $.reviews[reviewId];
        if (review.id == 0) revert ReviewNotFound(reviewId);
        return review;
    }

    /// @notice Returns all review IDs for a given app.
    function getAppReviewIds(bytes32 appId) external view returns (uint256[] memory) {
        return _getStorage().appReviewIds[appId];
    }

    /// @notice Returns all review IDs created by a user.
    function getUserReviewIds(address user) external view returns (uint256[] memory) {
        return _getStorage().userReviewIds[user];
    }

    /// @notice Returns aggregate review stats for an app.
    /// @return count Total number of reviews.
    /// @return avgRating Deprecated — always 0. Use getAppRatingStats() for rating data.
    function getAppReviewStats(bytes32 appId) external view returns (uint256 count, uint256 avgRating) {
        count = _getStorage().appReviewCount[appId];
    }

    /// @notice Returns the vote history for a review.
    function getVoteHistory(uint256 reviewId) external view returns (VoteEntry[] memory) {
        XAppReviewManagerStorage storage $ = _getStorage();
        if ($.reviews[reviewId].id == 0) revert ReviewNotFound(reviewId);
        return $.voteHistory[reviewId];
    }

    /// @notice Returns which vote types a user has cast on a review.
    /// @return upvoted True if the user has upvoted.
    /// @return downvoted True if the user has downvoted.
    /// @return reported True if the user has reported.
    function getUserVotes(uint256 reviewId, address user)
        external
        view
        returns (bool upvoted, bool downvoted, bool reported)
    {
        XAppReviewManagerStorage storage $ = _getStorage();
        return (
            $.reviewVotes[reviewId][user][VoteType.UPVOTE],
            $.reviewVotes[reviewId][user][VoteType.DOWNVOTE],
            $.reviewVotes[reviewId][user][VoteType.REPORT]
        );
    }

    /// @notice Returns the total number of reviews created (the next review ID minus 1).
    function totalReviews() external view returns (uint256) {
        return _getStorage().nextReviewId - 1;
    }

    /// @notice Returns a user's rating for an app (0 if not rated).
    function getUserRating(bytes32 appId, address user) external view returns (uint8) {
        return _getStorage().userRatings[appId][user];
    }

    /// @notice Returns aggregate rating stats for an app.
    /// @return count Total number of unique raters.
    /// @return avgRating Average rating scaled by 100 (divide by 100 for display).
    function getAppRatingStats(bytes32 appId) external view returns (uint256 count, uint256 avgRating) {
        XAppReviewManagerStorage storage $ = _getStorage();
        count = $.appRatingCount[appId];
        if (count > 0) {
            avgRating = $.appRatingSum[appId] / count;
        }
    }
}
