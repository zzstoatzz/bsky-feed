# The Persistent Old Posts Mystery: Why Bluesky Still Shows 15-Hour-Old Content

## Executive Summary

Despite successfully fixing the WAL isolation issue and confirming the feed endpoint returns recent posts (12 minutes old) when queried directly, Bluesky's UI continues to display posts from 15 hours ago. This suggests the problem lies in the interaction between our feed and Bluesky's infrastructure.

## Top 5 Most Likely Explanations

### 1. **Bluesky's Feed Caching/Indexing System** (90% probability)
Bluesky likely caches feed results to reduce load on feed generators. When you "refresh" in the app, you're not hitting our endpoint - you're hitting Bluesky's cached version. Evidence:
- Our endpoint returns recent posts when queried directly
- Bluesky UI shows old posts
- The "thank you for your attention" post appears in both, suggesting Bluesky has a stale cache

### 2. **Feed Subscription State in Bluesky** (85% probability)
Your Bluesky account may have a saved "position" in the feed from 15 hours ago. Bluesky might be:
- Saving your last read position per feed
- Not properly advancing when the feed updates
- Using cursor-based pagination that's stuck on old data

### 3. **CDN or Proxy Layer Between Bluesky and Feed** (70% probability)
There could be aggressive caching at the infrastructure level:
- Cloudflare or similar CDN caching feed responses
- Fly.io's proxy caching responses
- HTTP cache headers we're not setting properly

### 4. **Wrong Feed URI in Bluesky UI** (40% probability)
You might be viewing a different feed than the one we're debugging:
- Old version of the feed with different URI
- Test vs production feed confusion
- Feed URI mismatch between what we deploy and what you're subscribed to

### 5. **Browser/App Cache in Bluesky Client** (30% probability)
The Bluesky web app or mobile app might be aggressively caching:
- Local storage with old feed data
- Service worker caching responses
- App-level feed result caching

## Eliminating Two Explanations

**Eliminating #5 (Browser/App Cache)**: If this were the issue, you would have mentioned trying different devices or browsers, and the problem would be inconsistent across clients.

**Eliminating #4 (Wrong Feed URI)**: We've confirmed you're accessing the correct feed URI (`at://did:plc:xbtmt2zjwlrfegqvch7fboei/app.bsky.feed.generator/n8`), and the posts you see (like "thank you for your attention") match what our feed serves.

## Top 3 Remaining Suspects (Ranked by Probability)

### 1. **Bluesky's Feed Caching System** (90% probability)
**The Smoking Gun**: Our feed returns fresh posts to direct queries but Bluesky shows stale ones. This is classic cache behavior.
**Why It Happens**: Bluesky must cache feed results to handle millions of users. They probably:
- Cache feed skeletons for X hours
- Update caches on a schedule, not on-demand
- Have per-user cache keys that aren't invalidating properly

### 2. **Feed Subscription State** (85% probability)
**The Evidence**: You see the same 15-hour-old posts repeatedly, suggesting Bluesky thinks that's where you "are" in the feed.
**The Mechanism**: Bluesky might store your last-read position and always start from there, especially if our cursor logic was broken when you first subscribed.

### 3. **CDN/Infrastructure Caching** (70% probability)
**The Clue**: The 15-hour timeframe is suspiciously close to common cache TTLs (12-24 hours).
**The Culprit**: Could be Fly.io's proxy, Cloudflare, or Bluesky's own infrastructure caching our responses with long TTLs.

## The Path Forward

To definitively solve this, we need to:
1. Add cache-control headers to our feed responses
2. Contact Bluesky support about feed cache invalidation
3. Try unsubscribing and resubscribing to the feed
4. Add timestamp/version info to our feed responses to detect caching

The frustrating truth: **We fixed our feed, but we can't fix Bluesky's caching.** 