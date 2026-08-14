import { spawn, type ChildProcess } from "node:child_process";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { afterAll, beforeAll, describe, expect, it } from "vitest";
import {
  createPublicClient,
  createWalletClient,
  http,
  parseEther,
  type Account,
  type PublicClient,
  type WalletClient,
  type Address,
  type Hex,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { foundry } from "viem/chains";

import { EVMChainAdapter } from "../src/chains/evm.js";
import { ApprovalMode, EscrowState } from "../src/types.js";

const __dirname = dirname(fileURLToPath(import.meta.url));
const OUT = join(__dirname, "../../contracts/out");

const RPC_URL = "http://127.0.0.1:8545";

const FUNDER_ACCOUNT = privateKeyToAccount(
  "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80",
);
const RECIPIENT_ACCOUNT = privateKeyToAccount(
  "0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d",
);
const FUNDER = FUNDER_ACCOUNT.address;
const RECIPIENT = RECIPIENT_ACCOUNT.address;

// Canonical destination-token id used across all three payment modes. The
// router only accepts a `destToken` registered via `setTokenMapping`.
const DEST_TOKEN = ("0x" + "22".repeat(32)) as Hex;

let anvil: ChildProcess;
let publicClient: PublicClient;
let walletClient: WalletClient;
let recipientWallet: WalletClient;

let token: Address;
let sourceRouter: Address;
let destRouter: Address;
let bridge: Address;
let adapter: EVMChainAdapter;

function artifact(name: string) {
  const p = join(OUT, `${name}.sol/${name}.json`);
  const raw = JSON.parse(readFileSync(p, "utf8"));
  const object: string = raw.bytecode.object;
  return {
    abi: raw.abi,
    bytecode: (object.startsWith("0x") ? object : `0x${object}`) as Hex,
  };
}

async function deploy(name: string, args: unknown[] = []): Promise<Address> {
  const { abi, bytecode } = artifact(name);
  const hash = await walletClient.deployContract({ abi, bytecode, args });
  const receipt = await publicClient.waitForTransactionReceipt({ hash });
  return receipt.contractAddress!;
}

async function write(
  client: WalletClient,
  account: Account,
  address: Address,
  abi: unknown[],
  functionName: string,
  args: unknown[],
) {
  const hash = await client.writeContract({
    address,
    abi,
    functionName,
    args,
    account,
    chain: foundry,
  } as never);
  await publicClient.waitForTransactionReceipt({ hash: hash as Hex });
}

async function increaseTime(seconds: number) {
  await publicClient.request({ method: "evm_increaseTime", params: [seconds] });
  await publicClient.request({ method: "evm_mine", params: [] });
}

beforeAll(async () => {
  const anvilBin = process.env.ANVIL_BIN ?? "anvil";
  anvil = spawn(anvilBin, ["--port", "8545", "--silent"], { stdio: "ignore" });

  publicClient = createPublicClient({ transport: http(RPC_URL), chain: foundry });
  walletClient = createWalletClient({
    transport: http(RPC_URL),
    chain: foundry,
    account: FUNDER_ACCOUNT,
  });
  recipientWallet = createWalletClient({
    transport: http(RPC_URL),
    chain: foundry,
    account: RECIPIENT_ACCOUNT,
  });

  for (let i = 0; i < 50; i++) {
    try {
      await publicClient.getBlockNumber();
      break;
    } catch {
      await new Promise((r) => setTimeout(r, 200));
    }
  }

  token = await deploy("MockERC20");
  sourceRouter = await deploy("PaymentRouter", [1n]);
  destRouter = await deploy("PaymentRouter", [1500n]);
  bridge = await deploy("MockBridgeAdapter");

  const bridgeAbi = artifact("MockBridgeAdapter").abi;
  const routerAbi = artifact("PaymentRouter").abi;
  const tokenAbi = artifact("MockERC20").abi;

  await write(walletClient, FUNDER_ACCOUNT, bridge, bridgeAbi, "setRouter", [1n, sourceRouter]);
  await write(walletClient, FUNDER_ACCOUNT, bridge, bridgeAbi, "setRouter", [1500n, destRouter]);
  await write(walletClient, FUNDER_ACCOUNT, sourceRouter, routerAbi, "setBridge", [bridge]);
  await write(walletClient, FUNDER_ACCOUNT, destRouter, routerAbi, "setBridge", [bridge]);

  // Register the token mapping (source) and destination allowlist.
  await write(walletClient, FUNDER_ACCOUNT, sourceRouter, routerAbi, "setTokenMapping", [
    token,
    1500n,
    DEST_TOKEN,
  ]);
  await write(walletClient, FUNDER_ACCOUNT, destRouter, routerAbi, "setAllowedDestToken", [
    DEST_TOKEN,
    true,
  ]);

  await write(walletClient, FUNDER_ACCOUNT, token, tokenAbi, "mint", [FUNDER, parseEther("1000")]);
  await write(walletClient, FUNDER_ACCOUNT, token, tokenAbi, "approve", [sourceRouter, parseEther("1000")]);

  adapter = new EVMChainAdapter({
    chainId: 1,
    routerAddress: sourceRouter,
    publicClient,
    walletClient,
  });
}, 60_000);

afterAll(() => {
  anvil?.kill();
});

describe("EVMChainAdapter (Anvil)", () => {
  it("routes a one-time payment and reads its status", async () => {
    const { messageId } = await adapter.sendPayment({
      sender: FUNDER,
      token,
      destToken: DEST_TOKEN,
      amount: parseEther("10"),
      recipient: RECIPIENT,
      destChainId: 1500,
      timeout: Math.floor(Date.now() / 1000) + 1000,
    });

    const status = await adapter.getPaymentStatus({ messageId });
    expect(status.mode).toBe(0);
    expect(status.state).toBe(EscrowState.Funded);
    expect(status.totalAmount).toBe(parseEther("10"));
  });

  it("creates a stream, withdraws accrued funds, and reflects state", async () => {
    const { escrowAddress } = await adapter.streamPayment({
      sender: FUNDER,
      token,
      destToken: DEST_TOKEN,
      amount: parseEther("100"),
      recipient: RECIPIENT,
      destChainId: 1500,
      duration: 100,
      timeout: Math.floor(Date.now() / 1000) + 1000,
    });

    await increaseTime(50);
    const { abi } = artifact("StreamEscrow");
    await write(recipientWallet, RECIPIENT_ACCOUNT, escrowAddress, abi, "withdraw", []);

    const status = await adapter.getPaymentStatus({ escrowAddress });
    expect(status.state).toBe(EscrowState.Streaming);
    expect(status.releasedAmount).toBe(parseEther("50"));
    expect(status.releasableAmount).toBe(0n);
  });

  it("creates a milestone payment and releases a tranche after approval", async () => {
    const { escrowAddress } = await adapter.createMilestonePayment({
      sender: FUNDER,
      token,
      destToken: DEST_TOKEN,
      amount: parseEther("100"),
      recipient: RECIPIENT,
      destChainId: 1500,
      trancheAmounts: [parseEther("60"), parseEther("40")],
      approvalMode: ApprovalMode.Multisig,
      approvers: [FUNDER],
      threshold: 1,
      oracle: "0x0000000000000000000000000000000000000000",
      releaseDeadline: Math.floor(Date.now() / 1000) + 1000,
      timeout: Math.floor(Date.now() / 1000) + 1000,
    });

    await adapter.approveMilestone(escrowAddress, FUNDER, 0);
    await adapter.releaseMilestone(escrowAddress, 0);

    const status = await adapter.getPaymentStatus({ escrowAddress });
    expect(status.state).toBe(EscrowState.PartiallyReleased);
    expect(status.releasedAmount).toBe(parseEther("60"));
  });
});
