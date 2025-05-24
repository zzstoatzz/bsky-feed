# The Bluesky Documentation Revelations

## Key Insights from Official Docs

After reviewing the [Bluesky feed documentation](https://docs.bsky.app/docs/tutorials/viewing-feeds) and [custom feeds tutorial](https://docs.bsky.app/docs/tutorials/custom-feeds), several critical points emerge that explain our issue:

### 1. **The AppView Layer** 🎯
The most important revelation: Bluesky uses an **AppView** layer between users and feed generators:

> "The AppView sends a getFeedSkeleton request to the service endpoint declared in the Feed Generator's DID doc"
> "The AppView hydrates the feed (user info, post contents, aggregates, etc.)"

This means:
- Users NEVER directly hit our feed endpoint
- The AppView acts as a caching/hydration layer
- Our feed only provides post URIs; Bluesky fetches and caches the actual content

### 2. **Cursor-Based Caching** 
The docs state:
> "This cursor is treated as an opaque value and fully at the Feed Generator's discretion"

Our cursor format (`{timestamp}::{cid}`) matches their recommendation, but this might be the problem:
- If Bluesky caches responses based on cursor values
- And you're stuck at a specific cursor position from 15 hours ago
- The AppView might be serving cached results for that cursor forever

### 3. **The 48-Hour Recommendation**
Interestingly, the docs suggest:
> "you can likely garbage collect any data that is older than 48 hours"

This implies Bluesky expects feeds to show recent content, yet their caching might work against this.

## The Real Problem

Based on the documentation, our issue is almost certainly:

1. **AppView Caching**: The AppView layer is caching our feed skeleton responses
2. **Cursor Position**: Your account is stuck at an old cursor position
3. **No Cache Invalidation**: There's no mechanism to force the AppView to refetch

## Solutions We Can Try

### 1. **Change the Cursor Format** 
If we change how we generate cursors, Bluesky might treat them as "new" and bypass the cache:
```python
# Instead of: "1747951842887::bafyreihzr4osryadzlnh2lgy52jzsr3hcvrp5bmfqrrbn7zgte5jug7ody"
# Try: "v2_1747951842887::bafyreihzr4osryadzlnh2lgy52jzsr3hcvrp5bmfqrrbn7zgte5jug7ody"
```

### 2. **Add Cache Headers**
The docs mention HTTP headers. We should add:
```python
@app.route("/xrpc/app.bsky.feed.getFeedSkeleton", methods=["GET"])
def get_feed_skeleton():
    # ... existing code ...
    response = jsonify(body)
    response.headers['Cache-Control'] = 'no-cache, no-store, must-revalidate'
    response.headers['Pragma'] = 'no-cache'
    response.headers['Expires'] = '0'
    return response
```

### 3. **Force a Feed Reset**
Since the feed is published under your personal DID, you might need to:
1. Unpublish the feed
2. Wait for caches to expire
3. Republish with a different record key

## The Smoking Gun

From the custom feeds doc:
> "Once they subscribe to a custom algorithm, it will appear in their home interface as one of their available feeds"

If you subscribed when the cursor logic was broken, your subscription might be permanently stuck at that position in the AppView's cache.

**The solution might be as simple as unsubscribing and resubscribing to your own feed!** 