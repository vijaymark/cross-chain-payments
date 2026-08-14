import { describe, expect, it, vi } from "vitest";

import { CrossChainClient } from "../src/client.js";
import type { ChainAdapter, OneTimeRequest, StreamRequest } from "../src/types.js";
import { EscrowState, PaymentMode } from "../src/types.js";

function mockAdapter(chainId: number): ChainAdapter {
  return {
    chainId,
    sendPayment: vi.fn(async () => ({ messageId: "0xabc" })),
    streamPayment: vi.fn(async () => ({ messageId: "0xdef", escrowAddress: "0x111" })),
    createMilestonePayment: vi.fn(async () => ({ messageId: "0x123", escrowAddress: "0x222" })),
    approveMilestone: vi.fn(async () => {}),
    releaseMilestone: vi.fn(async () => {}),
    cancelStream: vi.fn(async () => {}),
    refundOneTime: vi.fn(async () => {}),
    getPaymentStatus: vi.fn(async () => ({
      mode: PaymentMode.Stream,
      state: EscrowState.Streaming,
      totalAmount: 100n,
      releasedAmount: 0n,
      delivered: false,
    })),
  };
}

const oneTime: OneTimeRequest = {
  sender: "0x0000000000000000000000000000000000000001",
  token: "0x0000000000000000000000000000000000000002",
  destToken: "0x" + "00".repeat(32),
  amount: 100n,
  recipient: "0x0000000000000000000000000000000000000003",
  destChainId: 1500,
  timeout: 123,
};

const stream: StreamRequest = { ...oneTime, duration: 100 };

describe("CrossChainClient", () => {
  it("routes to the correct adapter by source chain", async () => {
    const evm = mockAdapter(1);
    const stellar = mockAdapter(1500);
    const client = new CrossChainClient([evm, stellar]);

    await client.streamPayment(1500, stream);

    expect(stellar.streamPayment).toHaveBeenCalledTimes(1);
    expect(evm.streamPayment).not.toHaveBeenCalled();
  });

  it("delegates every primitive to the resolved adapter", async () => {
    const adapter = mockAdapter(1);
    const client = new CrossChainClient([adapter]);

    await client.sendPayment(1, oneTime);
    await client.approveMilestone(1, "0x222", "0xAAA", 0);
    await client.releaseMilestone(1, "0x222", 0);
    await client.cancelStream(1, "0x111", oneTime.sender);
    await client.refundOneTime(1, "0xabc", oneTime.sender);
    await client.getPaymentStatus(1, { escrowAddress: "0x111" });

    expect(adapter.sendPayment).toHaveBeenCalledWith(oneTime);
    expect(adapter.approveMilestone).toHaveBeenCalledWith("0x222", "0xAAA", 0);
    expect(adapter.releaseMilestone).toHaveBeenCalledWith("0x222", 0);
    expect(adapter.cancelStream).toHaveBeenCalledWith("0x111", oneTime.sender);
    expect(adapter.refundOneTime).toHaveBeenCalledWith("0xabc", oneTime.sender);
    expect(adapter.getPaymentStatus).toHaveBeenCalledWith({ escrowAddress: "0x111" });
  });

  it("throws for an unregistered chain id", () => {
    const client = new CrossChainClient([mockAdapter(1)]);
    expect(() => client.adapter(999)).toThrow(/No chain adapter/);
  });
});
