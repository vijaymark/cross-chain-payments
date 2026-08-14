import {
  type Address,
  type Hex,
  type PublicClient,
  type WalletClient,
  parseAbi,
} from "viem";

import type {
  ChainAdapter,
  MilestoneRequest,
  OneTimeRequest,
  PaymentInitResult,
  PaymentStatus,
  StreamRequest,
} from "../types.js";
import { ApprovalMode, EscrowState, PaymentMode } from "../types.js";

const routerAbi = parseAbi([
  "function sendPayment(address token, uint256 amount, bytes32 destToken, address recipient, uint256 destChainId, uint256 timeout) returns (bytes32)",
  "function streamPayment(address token, uint256 amount, bytes32 destToken, address recipient, uint256 destChainId, uint256 duration, uint256 timeout) returns (bytes32, address)",
  "function createMilestonePayment(address token, uint256 amount, bytes32 destToken, address recipient, uint256 destChainId, uint256[] trancheAmounts, uint8 approvalMode, address[] approvers, uint256 threshold, address oracle, uint256 releaseDeadline, uint256 timeout) returns (bytes32, address)",
  "function refundOneTime(bytes32 messageId)",
  "function delivered(uint256 sourceChainId, uint256 nonce) view returns (bool)",
  "function oneTimeLocks(bytes32 messageId) view returns (address sender, address token, uint256 amount, uint256 timeout, bool settled, bool refunded)",
]);

const streamEscrowAbi = parseAbi([
  "function withdraw()",
  "function cancel()",
  "function releasableAmount() view returns (uint256)",
  "function refundableAmount() view returns (uint256)",
  "function withdrawn() view returns (uint256)",
  "function amount() view returns (uint256)",
  "function funded() view returns (bool)",
  "function cancelled() view returns (bool)",
]);

const milestoneEscrowAbi = parseAbi([
  "function approveMilestone(uint256 index)",
  "function releaseMilestone(uint256 index)",
  "function claimTimeoutRefund()",
  "function status() view returns (uint8)",
  "function releasedAmount() view returns (uint256)",
  "function unreleasedAmount() view returns (uint256)",
  "function amount() view returns (uint256)",
]);

export interface EVMChainAdapterOptions {
  chainId: number;
  routerAddress: Address;
  publicClient: PublicClient;
  walletClient: WalletClient;
}

const asAddress = (s: string): Address => s as Address;

/**
 * Ethereum (EVM) chain adapter. Submits transactions to the deployed
 * `PaymentRouter` and reads escrow state via viem.
 */
export class EVMChainAdapter implements ChainAdapter {
  readonly chainId: number;
  private readonly routerAddress: Address;
  private readonly publicClient: PublicClient;
  private readonly walletClient: WalletClient;

  constructor(opts: EVMChainAdapterOptions) {
    this.chainId = opts.chainId;
    this.routerAddress = opts.routerAddress;
    this.publicClient = opts.publicClient;
    this.walletClient = opts.walletClient;
  }

  async sendPayment(req: OneTimeRequest): Promise<{ messageId: string }> {
    const args = [
      asAddress(req.token),
      req.amount,
      req.destToken,
      asAddress(req.recipient),
      BigInt(req.destChainId),
      BigInt(req.timeout),
    ] as const;
    const account = asAddress(req.sender);

    const { result } = await this.publicClient.simulateContract({
      address: this.routerAddress,
      abi: routerAbi,
      functionName: "sendPayment",
      args,
      account,
    });

    const hash = await this.walletClient.writeContract({
      address: this.routerAddress,
      abi: routerAbi,
      functionName: "sendPayment",
      args,
      account,
      chain: this.walletClient.chain,
    });
    await this.publicClient.waitForTransactionReceipt({ hash });

    return { messageId: result as Hex };
  }

  async streamPayment(req: StreamRequest): Promise<PaymentInitResult> {
    const args = [
      asAddress(req.token),
      req.amount,
      req.destToken,
      asAddress(req.recipient),
      BigInt(req.destChainId),
      BigInt(req.duration),
      BigInt(req.timeout),
    ] as const;
    const account = asAddress(req.sender);

    const { result } = await this.publicClient.simulateContract({
      address: this.routerAddress,
      abi: routerAbi,
      functionName: "streamPayment",
      args,
      account,
    });

    const hash = await this.walletClient.writeContract({
      address: this.routerAddress,
      abi: routerAbi,
      functionName: "streamPayment",
      args,
      account,
      chain: this.walletClient.chain,
    });
    await this.publicClient.waitForTransactionReceipt({ hash });

    const [messageId, escrowAddress] = result as [Hex, Address];
    return { messageId, escrowAddress };
  }

  async createMilestonePayment(req: MilestoneRequest): Promise<PaymentInitResult> {
    const args = [
      asAddress(req.token),
      req.amount,
      req.destToken,
      asAddress(req.recipient),
      BigInt(req.destChainId),
      req.trancheAmounts,
      req.approvalMode as ApprovalMode,
      req.approvers.map(asAddress),
      BigInt(req.threshold),
      asAddress(req.oracle),
      BigInt(req.releaseDeadline),
      BigInt(req.timeout),
    ] as const;
    const account = asAddress(req.sender);

    const { result } = await this.publicClient.simulateContract({
      address: this.routerAddress,
      abi: routerAbi,
      functionName: "createMilestonePayment",
      args,
      account,
    });

    const hash = await this.walletClient.writeContract({
      address: this.routerAddress,
      abi: routerAbi,
      functionName: "createMilestonePayment",
      args,
      account,
      chain: this.walletClient.chain,
    });
    await this.publicClient.waitForTransactionReceipt({ hash });

    const [messageId, escrowAddress] = result as [Hex, Address];
    return { messageId, escrowAddress };
  }

  async approveMilestone(escrowAddress: string, approver: string, index: number): Promise<void> {
    await this.submit(
      milestoneEscrowAbi,
      asAddress(escrowAddress),
      "approveMilestone",
      [BigInt(index)],
      asAddress(approver),
    );
  }

  async releaseMilestone(escrowAddress: string, index: number): Promise<void> {
    await this.submit(milestoneEscrowAbi, asAddress(escrowAddress), "releaseMilestone", [
      BigInt(index),
    ]);
  }

  async cancelStream(escrowAddress: string, sender: string): Promise<void> {
    await this.submit(streamEscrowAbi, asAddress(escrowAddress), "cancel", [], asAddress(sender));
  }

  async refundOneTime(messageId: string, sender: string): Promise<void> {
    await this.submit(routerAbi, this.routerAddress, "refundOneTime", [messageId as Hex], asAddress(sender));
  }

  async getPaymentStatus(ref: {
    messageId?: string;
    escrowAddress?: string;
  }): Promise<PaymentStatus> {
    if (ref.escrowAddress) {
      return this.escrowStatus(asAddress(ref.escrowAddress));
    }
    if (ref.messageId) {
      return this.oneTimeStatus(ref.messageId as Hex);
    }
    throw new Error("getPaymentStatus requires messageId or escrowAddress");
  }

  // ---- internals ----

  private async submit(
    abi: ReturnType<typeof parseAbi>,
    address: Address,
    functionName: string,
    args: readonly unknown[],
    account?: `0x${string}`,
  ): Promise<void> {
    const hash = await this.walletClient.writeContract({
      address,
      abi,
      functionName,
      args,
      account,
      chain: this.walletClient.chain,
    } as never);
    await this.publicClient.waitForTransactionReceipt({ hash: hash as `0x${string}` });
  }

  private async escrowStatus(escrowAddress: Address): Promise<PaymentStatus> {
    const milestoneStatus = await this.publicClient
      .readContract({
        address: escrowAddress,
        abi: milestoneEscrowAbi,
        functionName: "status",
      })
      .catch(() => undefined);

    if (milestoneStatus !== undefined) {
      const [amount, released] = await Promise.all([
        this.publicClient.readContract({
          address: escrowAddress,
          abi: milestoneEscrowAbi,
          functionName: "amount",
        }),
        this.publicClient.readContract({
          address: escrowAddress,
          abi: milestoneEscrowAbi,
          functionName: "releasedAmount",
        }),
      ]);
      return {
        mode: PaymentMode.Milestone,
        state: milestoneStateToEnum(milestoneStatus as number),
        totalAmount: amount as bigint,
        releasedAmount: released as bigint,
        delivered: false,
      };
    }

    const [amount, withdrawn, releasable, cancelled, funded] = await Promise.all([
      this.publicClient.readContract({
        address: escrowAddress,
        abi: streamEscrowAbi,
        functionName: "amount",
      }),
      this.publicClient.readContract({
        address: escrowAddress,
        abi: streamEscrowAbi,
        functionName: "withdrawn",
      }),
      this.publicClient.readContract({
        address: escrowAddress,
        abi: streamEscrowAbi,
        functionName: "releasableAmount",
      }),
      this.publicClient.readContract({
        address: escrowAddress,
        abi: streamEscrowAbi,
        functionName: "cancelled",
      }),
      this.publicClient.readContract({
        address: escrowAddress,
        abi: streamEscrowAbi,
        functionName: "funded",
      }),
    ]);

    let state: EscrowState;
    if (!funded) state = EscrowState.Created;
    else if (cancelled) state = EscrowState.Cancelled;
    else if (withdrawn === amount) state = EscrowState.Completed;
    else state = EscrowState.Streaming;

    return {
      mode: PaymentMode.Stream,
      state,
      totalAmount: amount as bigint,
      releasedAmount: withdrawn as bigint,
      releasableAmount: releasable as bigint,
      delivered: false,
    };
  }

  private async oneTimeStatus(messageId: Hex): Promise<PaymentStatus> {
    const lock = (await this.publicClient.readContract({
      address: this.routerAddress,
      abi: routerAbi,
      functionName: "oneTimeLocks",
      args: [messageId],
    })) as [Address, Address, bigint, bigint, boolean, boolean];

    const [, , amount, , settled, refunded] = lock;

    return {
      mode: PaymentMode.OneTime,
      state: refunded ? EscrowState.Cancelled : settled ? EscrowState.Completed : EscrowState.Funded,
      totalAmount: amount,
      releasedAmount: refunded || settled ? amount : 0n,
      delivered: settled,
      settled,
    };
  }
}

function milestoneStateToEnum(status: number): EscrowState {
  switch (status) {
    case 0:
      return EscrowState.Created;
    case 3:
      return EscrowState.PartiallyReleased;
    case 4:
      return EscrowState.Completed;
    case 5:
      return EscrowState.Cancelled;
    default:
      return EscrowState.PendingMilestone;
  }
}
