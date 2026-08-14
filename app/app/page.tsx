"use client";

import { useState } from "react";
import type { Address, EIP1193Provider } from "viem";
import {
  ApprovalMode,
  CHAIN_IDS,
  CrossChainClient,
  type PaymentStatus,
} from "@cross-chain-payments/sdk";

type Mode = "one-time" | "stream" | "milestone";

const DEFAULT_TOKEN = "0x5FbDB2315678afecb367f032d93F642f64180aa3"; // local MockERC20
const DEFAULT_ROUTER = "0xe7f1725E7734CE288F8367e1Bb143E90bb3F0512"; // local PaymentRouter

export default function Home() {
  const [connected, setConnected] = useState<Address | null>(null);
  const [rpcUrl, setRpcUrl] = useState("http://127.0.0.1:8545");
  const [routerAddress, setRouterAddress] = useState(DEFAULT_ROUTER);
  const [token, setToken] = useState(DEFAULT_TOKEN);
  const [amount, setAmount] = useState("10");
  const [recipient, setRecipient] = useState("");
  const [destChainId, setDestChainId] = useState(String(CHAIN_IDS.STELLAR));
  const [mode, setMode] = useState<Mode>("one-time");
  const [duration, setDuration] = useState("86400");
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState("");
  const [result, setResult] = useState("");
  const [status, setStatus] = useState<PaymentStatus | null>(null);

  async function connectWallet() {
    setError("");
    const eth = (window as unknown as { ethereum?: EIP1193Provider }).ethereum;
    if (!eth) {
      setError("No injected wallet found. Install MetaMask (or run the demo against a local Anvil node).");
      return;
    }
    const accounts = (await eth.request({ method: "eth_requestAccounts" })) as Address[];
    setConnected(accounts[0]);
  }

  async function submit() {
    setError("");
    setResult("");
    setStatus(null);
    if (!connected) {
      setError("Connect a wallet first.");
      return;
    }
    if (!recipient) {
      setError("Enter a recipient address.");
      return;
    }

    const { createPublicClient, createWalletClient, custom, http, parseEther } = await import("viem");
    const { foundry } = await import("viem/chains");
    const { EVMChainAdapter } = await import("@cross-chain-payments/sdk");

    const eth = (window as unknown as { ethereum?: EIP1193Provider }).ethereum;
    const transport = eth ? custom(eth) : http(rpcUrl);

    const publicClient = createPublicClient({ transport, chain: foundry });
    const walletClient = createWalletClient({ transport, chain: foundry, account: connected });

    const adapter = new EVMChainAdapter({
      chainId: CHAIN_IDS.ETHEREUM,
      routerAddress: routerAddress as Address,
      publicClient,
      walletClient,
    });
    const c = new CrossChainClient([adapter]);

    const base = {
      sender: connected,
      token,
      destToken: ("0x" + "ab".repeat(32)) as `0x${string}`,
      amount: parseEther(amount),
      recipient,
      destChainId: Number(destChainId),
      timeout: Math.floor(Date.now() / 1000) + 3600,
    };

    try {
      setBusy(true);
      if (mode === "one-time") {
        const { messageId } = await c.sendPayment(CHAIN_IDS.ETHEREUM, base);
        setResult(`messageId: ${messageId}`);
        setStatus(await c.getPaymentStatus(CHAIN_IDS.ETHEREUM, { messageId }));
      } else if (mode === "stream") {
        const { messageId, escrowAddress } = await c.streamPayment(CHAIN_IDS.ETHEREUM, {
          ...base,
          duration: Number(duration),
        });
        setResult(`messageId: ${messageId}\nescrow: ${escrowAddress}`);
        setStatus(await c.getPaymentStatus(CHAIN_IDS.ETHEREUM, { escrowAddress }));
      } else {
        const trancheAmounts = [parseEther(amount)];
        const { messageId, escrowAddress } = await c.createMilestonePayment(CHAIN_IDS.ETHEREUM, {
          ...base,
          trancheAmounts,
          approvalMode: ApprovalMode.Multisig,
          approvers: [connected],
          threshold: 1,
          oracle: "0x0000000000000000000000000000000000000000",
          releaseDeadline: Math.floor(Date.now() / 1000) + 3600,
        });
        setResult(`messageId: ${messageId}\nescrow: ${escrowAddress}`);
        setStatus(await c.getPaymentStatus(CHAIN_IDS.ETHEREUM, { escrowAddress }));
      }
    } catch (e) {
      setError(e instanceof Error ? e.message : String(e));
    } finally {
      setBusy(false);
    }
  }

  return (
    <main>
      <h1>cross-chain-payments</h1>
      <p className="subtitle">
        Reference frontend: route a grant, salary, or donation from Ethereum to
        another chain in a single flow.
      </p>

      <div className="card">
        <div className="row" style={{ alignItems: "center", justifyContent: "space-between" }}>
          <span className="pill">
            <span className="dot" style={{ background: connected ? "#4ade80" : "#94a0c4" }} />
            {connected ? `Connected: ${connected.slice(0, 6)}…${connected.slice(-4)}` : "Not connected"}
          </span>
          <button className="secondary" onClick={connectWallet} disabled={!!connected}>
            {connected ? "Connected" : "Connect wallet"}
          </button>
        </div>
        <div className="muted" style={{ marginTop: 10 }}>
          Requires a wallet and a deployed <code>PaymentRouter</code>. Defaults
          target a local Anvil node; see the README quickstart to stand one up.
        </div>
      </div>

      <div className="card">
        <h2>Route</h2>
        <div className="row">
          <div className="field">
            <label>Source chain</label>
            <select value="1" disabled>
              <option value="1">Ethereum (EVM)</option>
            </select>
          </div>
          <div className="field">
            <label>Destination chain</label>
            <select value={destChainId} onChange={(e) => setDestChainId(e.target.value)}>
              <option value={String(CHAIN_IDS.STELLAR)}>Stellar (Soroban)</option>
              <option value="137">Polygon</option>
            </select>
          </div>
          <div className="field">
            <label>Payment mode</label>
            <select value={mode} onChange={(e) => setMode(e.target.value as Mode)}>
              <option value="one-time">One-time</option>
              <option value="stream">Stream</option>
              <option value="milestone">Milestone</option>
            </select>
          </div>
        </div>
      </div>

      <div className="card">
        <h2>Payment</h2>
        <div className="row">
          <div className="field">
            <label>Router address</label>
            <input value={routerAddress} onChange={(e) => setRouterAddress(e.target.value)} />
          </div>
          <div className="field">
            <label>Token address</label>
            <input value={token} onChange={(e) => setToken(e.target.value)} />
          </div>
        </div>
        <div className="row">
          <div className="field">
            <label>Amount (tokens)</label>
            <input value={amount} onChange={(e) => setAmount(e.target.value)} />
          </div>
          <div className="field">
            <label>Recipient address</label>
            <input value={recipient} onChange={(e) => setRecipient(e.target.value)} placeholder="0x…" />
          </div>
          {mode === "stream" && (
            <div className="field">
              <label>Duration (seconds)</label>
              <input value={duration} onChange={(e) => setDuration(e.target.value)} />
            </div>
          )}
        </div>
        <div className="row">
          <div className="field">
            <label>RPC URL</label>
            <input value={rpcUrl} onChange={(e) => setRpcUrl(e.target.value)} />
          </div>
        </div>
        <button onClick={submit} disabled={busy || !connected}>
          {busy ? "Submitting…" : "Submit payment"}
        </button>
      </div>

      {error && <div className="error">{error}</div>}

      {result && (
        <div className="card">
          <h2>Result</h2>
          <pre>{result}</pre>
          {status && (
            <pre>
              state: {status.state}
              {"\n"}mode: {status.mode}
              {"\n"}total: {status.totalAmount.toString()}
              {"\n"}released: {status.releasedAmount.toString()}
            </pre>
          )}
        </div>
      )}
    </main>
  );
}
