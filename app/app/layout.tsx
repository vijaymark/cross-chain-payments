import type { Metadata } from "next";
import "./globals.css";

export const metadata: Metadata = {
  title: "cross-chain-payments",
  description:
    "Route grant, salary, and donation payments across blockchains without managing bridges.",
};

export default function RootLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}
