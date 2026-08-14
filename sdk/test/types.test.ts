import { describe, expect, it } from "vitest";

import {
  ApprovalMode,
  CHAIN_IDS,
  EscrowState,
  PaymentMode,
} from "../src/types.js";

describe("protocol types", () => {
  it("payment modes match the protocol spec", () => {
    expect(PaymentMode.OneTime).toBe(0);
    expect(PaymentMode.Stream).toBe(1);
    expect(PaymentMode.Milestone).toBe(2);
  });

  it("approval modes match the protocol spec", () => {
    expect(ApprovalMode.Multisig).toBe(0);
    expect(ApprovalMode.Vote).toBe(1);
    expect(ApprovalMode.Oracle).toBe(2);
  });

  it("chain ids match the registry", () => {
    expect(CHAIN_IDS.ETHEREUM).toBe(1);
    expect(CHAIN_IDS.STELLAR).toBe(1500);
    expect(CHAIN_IDS.MOCK).toBe(0);
  });

  it("escrow states cover the documented lifecycle", () => {
    expect(EscrowState.Created).toBe("Created");
    expect(EscrowState.Funded).toBe("Funded");
    expect(EscrowState.Streaming).toBe("Streaming");
    expect(EscrowState.PendingMilestone).toBe("PendingMilestone");
    expect(EscrowState.PartiallyReleased).toBe("PartiallyReleased");
    expect(EscrowState.Completed).toBe("Completed");
    expect(EscrowState.Cancelled).toBe("Cancelled");
  });
});
