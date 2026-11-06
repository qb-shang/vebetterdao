import { getConfig } from "@repo/config"
import { EnvConfig, getContractsConfig } from "@repo/config/contracts"
import { deployProxy } from "../../helpers"
import { XAppReviewManager } from "../../../typechain-types"
import { ethers } from "hardhat"
import { updateConfig } from "../../helpers/config"
import { transferAdminRole, transferUpgraderRole } from "../../helpers/roles"

export async function main() {
  if (!process.env.NEXT_PUBLIC_APP_ENV) {
    throw new Error("Missing NEXT_PUBLIC_APP_ENV")
  }

  const envConfig = getConfig(process.env.NEXT_PUBLIC_APP_ENV as EnvConfig)
  const contractsConfig = getContractsConfig(process.env.NEXT_PUBLIC_APP_ENV as EnvConfig)
  const deployer = (await ethers.getSigners())[0]

  console.log(
    `================  Deploying contracts on ${envConfig.network.name} (${envConfig.nodeUrl}) with ${envConfig.environment} configurations `,
  )
  console.log(`================  Address used to deploy: ${deployer.address}`)

  const TEMP_ADMIN = envConfig.network.name === "solo" ? contractsConfig.CONTRACTS_ADMIN_ADDRESS : deployer.address
  console.log("Temporary admin set to ", TEMP_ADMIN)
  console.log("Final admin will be set to ", contractsConfig.CONTRACTS_ADMIN_ADDRESS)

  console.log("Deploying proxy for XAppReviewManager")

  const xAppReviewManager = (await deployProxy("XAppReviewManager", [
    TEMP_ADMIN,
    TEMP_ADMIN,
  ])) as unknown as XAppReviewManager

  console.log("XAppReviewManager deployed at:", await xAppReviewManager.getAddress())
  console.log("Version:", await xAppReviewManager.version())

  // Rating and review creation revert with PassportNotSet until the passport is linked.
  await (
    await xAppReviewManager.connect(deployer).setVeBetterPassport(envConfig.veBetterPassportContractAddress)
  ).wait()
  console.log("VeBetterPassport linked:", envConfig.veBetterPassportContractAddress)

  if (TEMP_ADMIN !== contractsConfig.CONTRACTS_ADMIN_ADDRESS) {
    await transferUpgraderRole(xAppReviewManager, deployer, contractsConfig.CONTRACTS_ADMIN_ADDRESS)
    await transferAdminRole(xAppReviewManager, deployer, contractsConfig.CONTRACTS_ADMIN_ADDRESS)
    console.log("Admin and upgrader roles transferred to", contractsConfig.CONTRACTS_ADMIN_ADDRESS)
  }

  console.log("Updating the config file with the new XAppReviewManager contract address")
  try {
    Object.assign(envConfig, { xAppReviewManagerContractAddress: await xAppReviewManager.getAddress() })
    await updateConfig(envConfig, "xAppReviewManagerContract")
    console.log("Config file updated successfully")
  } catch (e) {
    console.error("Failed to update config file, update it manually:", e)
  }

  console.log("XAppReviewManager address: ", await xAppReviewManager.getAddress())
  console.log("================  Execution completed")
  process.exit(0)
}

main()
