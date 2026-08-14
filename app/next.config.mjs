/** @type {import('next').NextConfig} */
const nextConfig = {
  reactStrictMode: true,
  // The SDK is a sibling workspace package; transpile it so it is bundled
  // even though it lives outside the app/ project root.
  transpilePackages: ["@ipay/sdk"],
};

export default nextConfig;
