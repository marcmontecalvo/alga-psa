/**
 * PostHog Configuration
 *
 * This file contains public configuration for PostHog analytics.
 * The API key is supplied by the local deployment environment.
 */

const defaultApiKey = '';
const defaultApiHost = 'https://us.i.posthog.com';
const defaultUiHost = 'https://us.posthog.com';
const publicApiHost = process.env.NEXT_PUBLIC_POSTHOG_HOST || defaultApiHost;
const apiHost = typeof window === 'undefined'
  ? process.env.POSTHOG_HOST || publicApiHost
  : publicApiHost;

export const posthogConfig = {
  // Public project key supplied by the local deployment environment
  apiKey: process.env.NEXT_PUBLIC_POSTHOG_API_KEY || process.env.POSTHOG_API_KEY || defaultApiKey,

  // PostHog instance URL
  apiHost,

  // Ingestion endpoint (used by Next.js rewrites)
  ingestHost: apiHost,

  // UI host for PostHog toolbar and debugging
  uiHost: process.env.NEXT_PUBLIC_POSTHOG_UI_HOST ||
    (process.env.NEXT_PUBLIC_POSTHOG_HOST ? publicApiHost : defaultUiHost),

  // Default configuration
  defaultConfig: {
    capture_pageview: 'history_change' as const,
    capture_pageleave: true,
    capture_exceptions: true,
    autocapture: true,
    disable_session_recording: true,
  },

  // Feature flags
  features: {
    sessionRecording: false,
    featureFlags: true,
    experiments: false,
  },
}

// Helper to check if usage statistics should be enabled
export function isPostHogEnabled(): boolean {
  // Check environment variable override
  // Using generic name so we can switch providers in the future
  if (process.env.ALGA_USAGE_STATS === 'false' ||
      process.env.NEXT_PUBLIC_ALGA_USAGE_STATS === 'false') {
    return false;
  }

  // Usage statistics are enabled by default
  return true;
}
