import type {
  ChainAdapter,
  MilestoneRequest,
  OneTimeRequest,
  PaymentInitResult,
  PaymentStatus,
  StreamRequest,
} from "./types.js";

/**
 * Chain-agnostic client. Register one `ChainAdapter` per supported chain, then
 * initiate and track payments without worrying about which chain is involved.
 *
 * ```ts
 * const client = new CrossChainClient([evmAdapter, stellarAdapter]);
 * const { messageId, escrowAddress } = await client.streamPayment(CHAIN_IDS.ETHEREUM, {
 *   sender, token, destToken, amount, recipient, destChainId: CHAIN_IDS.STELLAR,
 *   duration, timeout,
 * });
 * ```
 */
export class CrossChainClient {
  private readonly adapters: Map<number, ChainAdapter>;

  constructor(adapters: ChainAdapter[]) {
    this.adapters = new Map(adapters.map((a) => [a.chainId, a]));
  }

  /** Resolve the adapter for a source chain id. */
  adapter(chainId: number): ChainAdapter {
    const adapter = this.adapters.get(chainId);
    if (!adapter) {
      throw new Error(`No chain adapter registered for chain id ${chainId}`);
    }
    return adapter;
  }

  /** Route a one-time payment from `sourceChainId` to `req.destChainId`. */
  sendPayment(sourceChainId: number, req: OneTimeRequest): Promise<{ messageId: string }> {
    return this.adapter(sourceChainId).sendPayment(req);
  }

  /** Route a streamed payment from `sourceChainId` to `req.destChainId`. */
  streamPayment(sourceChainId: number, req: StreamRequest): Promise<PaymentInitResult> {
    return this.adapter(sourceChainId).streamPayment(req);
  }

  /** Route a milestone payment from `sourceChainId` to `req.destChainId`. */
  createMilestonePayment(sourceChainId: number, req: MilestoneRequest): Promise<PaymentInitResult> {
    return this.adapter(sourceChainId).createMilestonePayment(req);
  }

  approveMilestone(
    sourceChainId: number,
    escrowAddress: string,
    approver: string,
    index: number,
  ): Promise<void> {
    return this.adapter(sourceChainId).approveMilestone(escrowAddress, approver, index);
  }

  releaseMilestone(sourceChainId: number, escrowAddress: string, index: number): Promise<void> {
    return this.adapter(sourceChainId).releaseMilestone(escrowAddress, index);
  }

  cancelStream(sourceChainId: number, escrowAddress: string, sender: string): Promise<void> {
    return this.adapter(sourceChainId).cancelStream(escrowAddress, sender);
  }

  refundOneTime(sourceChainId: number, messageId: string, sender: string): Promise<void> {
    return this.adapter(sourceChainId).refundOneTime(messageId, sender);
  }

  getPaymentStatus(
    sourceChainId: number,
    ref: { messageId?: string; escrowAddress?: string },
  ): Promise<PaymentStatus> {
    return this.adapter(sourceChainId).getPaymentStatus(ref);
  }
}
