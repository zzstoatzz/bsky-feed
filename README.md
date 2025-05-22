# deploy a bsky feed on fly.io

0. clone the repo
```
git clone https://github.com/zzstoatzz/bsky-feed.git
```

1. copy `.env.example` to `.env` and set variables (except `FEED_URI`)

2. run `just publish` to publish the feed, which gives the `FEED_URI` and that you copy into `.env`

3. implement `example_custom_filters.py` to customize your feed

4. run `just docker-test` to test the docker image with your .env file

5. run `just deploy` to deploy the app to fly.io

## Troubleshooting Notes

I had some issues with the feed falling behind, which I cronicled in [./documents/firehose_cursor_issue_resolution.md](./documents/firehose_cursor_issue_resolution.md).

<details>
<summary>original template documentation</summary>

# ATProto Feed Generator powered by [The AT Protocol SDK for Python](https://github.com/MarshalX/atproto)

> Feed Generators are services that provide custom algorithms to users through the AT Protocol.

Official overview (read it first): https://github.com/bluesky-social/feed-generator#overview

## Getting Started

We've set up this simple server with SQLite to store and query data. Feel free to switch this out for whichever database you prefer.

Next, you will need to do two things:

1. Implement filtering logic in `server/data_filter.py`.
2. Copy `.env.example` to `.env`
3. Optionally implement custom feed generation logic in `server/algos`.

We've taken care of setting this server up with a did:web. However, you're free to switch this out for did:plc if you like - you may want to if you expect this Feed Generator to be long-standing and possibly migrating domains.

## Publishing your feed

To publish your feed, simply run `python publish_feed.py`.

To update your feed's display data (name, avatar, description, etc.), just update the relevant variables in `.env` and re-run the script.

After successfully running the script, you should be able to see your feed from within the app, as well as share it by embedding a link in a post (similar to a quote post).

## Running the Server

Install Python 3.7+.

Run `setupvenv.sh` to setup a virtual environment and install the dependencies:

```shell
./setupvenv.sh
```

**Note**: To get value for `FEED_URI` you need to publish the feed first

To run a development Flask server:

```shell
flask run
```

**Warning** The Flask development server is not designed for production use. In production, you should use production WSGI server such as [`waitress`](https://flask.palletsprojects.com/en/stable/deploying/waitress/) behind a reverse proxy such as NGINX instead.

```shell
pip install waitress
waitress-serve --listen=127.0.0.1:8080 server.app:app
```

To run a development server with debugging:

```shell
flask --debug run
```

**Note**: Duplication of data stream instances in debug mode is fine.

**Warning**: If you want to run server in many workers, you should run Data Stream (Firehose) separately.

### Endpoints

- `/.well-known/did.json`
- `/xrpc/app.bsky.feed.describeFeedGenerator`
- `/xrpc/app.bsky.feed.getFeedSkeleton`

## License

MIT



</details>
