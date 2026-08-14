/**
 * Shared types for the cross-chain-payments SDK. These mirror the canonical
 * message format in `docs/PROTOCOL_SPEC.md` §4 and the on-chain enums.
 */

/** Payment primitives supported by the protocol. */
export enum PaymentMode {
  OneTime = 0,
  Stream = 1,
  Milestone = 2,
}

/** Approval mechanism for milestone tranche release. */
export enum ApprovalMode {
  Multisig = 0,
  Vote = 1,
  Oracle = 2,
}

/** Escrow lifecycle state (PROTOCOL_SPEC.md §5). */
export enum EscrowState {
  Created = "Created",
  Funded = "Funded",
  Streaming = "Streaming",
  PendingMilestone = "PendingMilestone",
  PartiallyReleased = "PartiallyReleased",
  Completed = "Completed",
  Cancelled = "Cancelled",
}

/**
 * Canonical cross-chain message (PROTOCOL_SPEC.md §4).
 *
 * `token` is a 32-byte hex string (left-padded address on EVM, contract id on
 * Soroban). `recipient` and `metadata` are hex-encoded bytes.
 */
export interface CrossChainMessage {
  nonce: bigint;
  sourceChainId: bigint;
  destChainId: bigint;
  token: `0x${string}`;
  amount: bigint;
  recipient: `0x${string}`;
  mode: PaymentMode;
  metadata: `0x${string}`;
}

/** A chain id registry entry (PROTOCOL_SPEC.md §2). */
export const CHAIN_IDS = {
  ETHEREUM: 1,
  STELLAR: 1500,
  MOCK: 0,
} as const;

/** Common fields for every payment request. */
interface BaseRequest {
  /** Address of the funder on the source chain (per-chain encoding). */
  sender: string;
  /** Token contract/asset address on the source chain (per-chain encoding). */
  token: string;
  /** Canonical token id on the destination chain (32-byte hex). */
  destToken: `0x${string}`;
  /** Base-unit amount (wei / stroops). */
  amount: bigint;
  /** Destination address, per-chain encoded (20-byte EVM / 32-byte Soroban). */
  recipient: string;
  /** Destination chain id (see CHAIN_IDS). */
  destChainId: number;
  /** Unix-seconds deadline after which the sender may recover undelivered funds. */
  timeout: number;
}

export type OneTimeRequest = BaseRequest;

export interface StreamRequest extends BaseRequest {
  /** Total stream duration in seconds. */
  duration: number;
}

export interface MilestoneRequest extends BaseRequest {
  /** Per-tranche amounts; sum must equal `amount`. */
  trancheAmounts: bigint[];
  approvalMode: ApprovalMode;
  /** Multisig owners / DAO voters (ignored for Oracle mode). */
  approvers: string[];
  /** m-of-n threshold (ignored for Vote/Oracle). */
  threshold: number;
  /** Attestation key (Oracle mode only). */
  oracle: string;
  /** Unix-seconds deadline for the timeout fallback. */
  releaseDeadline: number;
}

/** Snapshot of a payment's lifecycle, for status queries. */
export interface PaymentStatus {
  mode: PaymentMode;
  state: EscrowState;
  /** Total funded amount. */
  totalAmount: bigint;
  /** Amount already released/withdrawn. */
  releasedAmount: bigint;
  /** Currently withdrawable amount (streams only). */
  releasableAmount?: bigint;
  /** Whether the cross-chain message reached the destination. */
  delivered: boolean;
  /** One-time payments only: whether the destination confirmed delivery. */
  settled?: boolean;
}

/** Result of initiating a streamed or milestone payment. */
export interface PaymentInitResult {
  messageId: string;
  escrowAddress: string;
}

/**
 * A chain-specific signing/submission adapter. The client delegates to one of
 * these for every operation; the client itself is chain-agnostic.
 */
export interface ChainAdapter {
  /** Protocol chain id this adapter targets (see CHAIN_IDS). */
  readonly chainId: number;

  sendPayment(req: OneTimeRequest): Promise<{ messageId: string }>;
  streamPayment(req: StreamRequest): Promise<PaymentInitResult>;
  createMilestonePayment(req: MilestoneRequest): Promise<PaymentInitResult>;

  /** Record a multisig/vote approval for a milestone tranche. */
  approveMilestone(escrowAddress: string, approver: string, index: number): Promise<void>;
  /** Release an approved tranche to the recipient. */
  releaseMilestone(escrowAddress: string, index: number): Promise<void>;
  /** Sender cancels a stream with pro-rata settlement. */
  cancelStream(escrowAddress: string, sender: string): Promise<void>;
  /** Sender recovers a one-time payment after timeout. */
  refundOneTime(messageId: string, sender: string): Promise<void>;

  getPaymentStatus(ref: { messageId?: string; escrowAddress?: string }): Promise<PaymentStatus>;
}
