import { Client, type AssembledTransaction } from "@stellar/stellar-sdk/contract";
import type { ClientOptions } from "@stellar/stellar-sdk/contract";

import type {
  ChainAdapter,
  MilestoneRequest,
  OneTimeRequest,
  PaymentInitResult,
  PaymentStatus,
  StreamRequest,
} from "../types.js";
import { CHAIN_IDS, EscrowState, PaymentMode } from "../types.js";

export interface StellarChainAdapterOptions {
  /** Deployed PaymentRouter contract id (C…). */
  routerContractId: string;
  /** Soroban RPC endpoint (e.g. https://soroban-testnet.stellar.org). */
  rpcUrl: string;
  /** Network passphrase (Soroban testnet / mainnet). */
  networkPassphrase: string;
  /** Public key that signs the submitted transactions. */
  publicKey: string;
  /** Signs an XDR envelope (matches Freighter's `signTransaction`). */
  signTransaction: ClientOptions["signTransaction"];
  /** Signs a preimage auth entry (matches Freighter's `signAuthEntry`). */
  signAuthEntry?: ClientOptions["signAuthEntry"];
}

type AnyClient = Client & Record<string, (args: object) => AssembledTransaction<unknown>>;

/**
 * Stellar (Soroban) chain adapter. Mirrors the EVM adapter against the Soroban
 * `PaymentRouter` contract, using @stellar/stellar-sdk's spec-generated client.
 *
 * Addresses are Stellar StrKey strings (G… accounts, C… contracts). Amounts are
 * bigint stroops. `ApprovalMode` is passed as its enum index (0/1/2).
 */
export class StellarChainAdapter implements ChainAdapter {
  readonly chainId = CHAIN_IDS.STELLAR;
  private readonly clientPromise: Promise<Client>;

  constructor(opts: StellarChainAdapterOptions) {
    this.clientPromise = Client.from({
      contractId: opts.routerContractId,
      rpcUrl: opts.rpcUrl,
      networkPassphrase: opts.networkPassphrase,
      publicKey: opts.publicKey,
      signTransaction: opts.signTransaction,
      signAuthEntry: opts.signAuthEntry,
    });
  }

  private async client(): Promise<AnyClient> {
    return (await this.clientPromise) as AnyClient;
  }

  private async send<T>(tx: AssembledTransaction<T>): Promise<T> {
    const sent = await tx.signAndSend();
    return sent.result as T;
  }

  async sendPayment(req: OneTimeRequest): Promise<{ messageId: string }> {
    const client = await this.client();
    const deliveryId = await this.send(
      client.send_payment({
        sender: req.sender,
        token: req.token,
        amount: req.amount,
        recipient: req.recipient,
        dest_chain_id: req.destChainId,
        timeout: req.timeout,
      }),
    );
    return { messageId: String(deliveryId) };
  }

  async streamPayment(req: StreamRequest): Promise<PaymentInitResult> {
    const client = await this.client();
    const [deliveryId, escrowAddress] = (await this.send(
      client.stream_payment({
        sender: req.sender,
        token: req.token,
        amount: req.amount,
        recipient: req.recipient,
        dest_chain_id: req.destChainId,
        duration: req.duration,
        timeout: req.timeout,
      }),
    )) as [bigint, string];
    return { messageId: String(deliveryId), escrowAddress };
  }

  async createMilestonePayment(req: MilestoneRequest): Promise<PaymentInitResult> {
    const client = await this.client();
    const [deliveryId, escrowAddress] = (await this.send(
      client.create_milestone_payment({
        sender: req.sender,
        token: req.token,
        amount: req.amount,
        recipient: req.recipient,
        dest_chain_id: req.destChainId,
        tranche_amounts: req.trancheAmounts,
        mode: req.approvalMode, // enum index (0/1/2)
        approvers: req.approvers,
        threshold: req.threshold,
        oracle: req.oracle,
        release_deadline: req.releaseDeadline,
        timeout: req.timeout,
      }),
    )) as [bigint, string];
    return { messageId: String(deliveryId), escrowAddress };
  }

  async approveMilestone(escrowAddress: string, approver: string, index: number): Promise<void> {
    const client = await this.clientFor(escrowAddress);
    await this.send(client.approve_milestone({ approver, index }));
  }

  async releaseMilestone(escrowAddress: string, index: number): Promise<void> {
    const client = await this.clientFor(escrowAddress);
    await this.send(client.release_milestone({ index }));
  }

  async cancelStream(escrowAddress: string): Promise<void> {
    const client = await this.clientFor(escrowAddress);
    await this.send(client.cancel({}));
  }

  async refundOneTime(messageId: string, sender: string): Promise<void> {
    const client = await this.client();
    await this.send(
      client.refund_one_time({
        sender,
        delivery_id: Number(messageId),
      }),
    );
  }

  async getPaymentStatus(ref: {
    messageId?: string;
    escrowAddress?: string;
  }): Promise<PaymentStatus> {
    if (ref.escrowAddress) {
      const client = await this.clientFor(ref.escrowAddress);
      const status = await this.send(client.status({}));
      const released = await this.send(client.released_amount({}));
      return {
        mode: PaymentMode.Milestone,
        state: milestoneStateToEnum(Number(status)),
        totalAmount: 0n,
        releasedAmount: BigInt(String(released)),
        delivered: false,
      };
    }
    if (ref.messageId) {
      const client = await this.client();
      const lock = (await this.send(
        client.one_time_lock({ delivery_id: Number(ref.messageId) }),
      )) as { amount: bigint; settled: boolean; refunded: boolean };
      return {
        mode: PaymentMode.OneTime,
        state: lock.refunded
          ? EscrowState.Cancelled
          : lock.settled
            ? EscrowState.Completed
            : EscrowState.Funded,
        totalAmount: lock.amount,
        releasedAmount: lock.refunded || lock.settled ? lock.amount : 0n,
        delivered: lock.settled,
        settled: lock.settled,
      };
    }
    throw new Error("getPaymentStatus requires messageId or escrowAddress");
  }

  private async clientFor(contractId: string): Promise<AnyClient> {
    const router = await this.clientPromise;
    const options = router.options;
    const client = await Client.from({
      ...options,
      contractId,
    });
    return client as AnyClient;
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
