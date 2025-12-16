# Migration Plan: DynamoDB to ScyllaDB for amazon-dynamodb-chat-sample

Author: Devin (Cognition AI)
Date: 2025-12-16

Summary
This document is a step-by-step blueprint for migrating the serverless real-time chat sample from DynamoDB to ScyllaDB. It explains current architecture and access patterns, proposes equivalent ScyllaDB schemas, details query translations, outlines dual-write/backfill cutover, and covers performance, testing, and rollout/rollback. The guidance is written for a junior engineer to follow end-to-end.

Repo references
- API layer: <ref_file file="/home/ubuntu/repos/amazon-dynamodb-chat-sample/app.py" />
- DynamoDB client: <ref_file file="/home/ubuntu/repos/amazon-dynamodb-chat-sample/chalicelib/ddb.py" />
- Frontend: <ref_file file="/home/ubuntu/repos/amazon-dynamodb-chat-sample/chalicelib/livechat.html" />
- Tests: <ref_file file="/home/ubuntu/repos/amazon-dynamodb-chat-sample/tests/test_app.py" />


1. Architecture Analysis

1.1 Current DynamoDB architecture

Table: chat
- Primary key: name (partition key), time (sort key)
- Attributes: name, time (microsecond Unix timestamp stored as string), comment, chat_room
- GSI: chat_room_time_idx with chat_room (partition key), time (sort key), projection: ALL

Observed access patterns
- All reads go through the GSI chat_room_time_idx to fetch messages by room in time order
- Latest N messages for a room (descending time)
- All messages for a room (paged)
- Messages after a given timestamp (paged)
- Writes insert items with ConditionExpression attribute_not_exists(#T) AND attribute_not_exists(#N) to prevent duplicate primary key writes

ASCII diagram of current architecture:

+---------------------------+           +-----------------------------+
|        Vue.js SPA         |  HTTP     |   AWS Chalice (Lambda)      |
|  chalicelib/livechat.html +---------->+ app.py routes               |
+---------------------------+           |  /chat/comments/*           |
                                        +--------------+--------------+
                                                       |
                                                       | boto3
                                                       v
                                        +--------------+--------------+
                                        |         DynamoDB            |
                                        |  Table: chat                |
                                        |  PK: (name, time)           |
                                        |  GSI: chat_room_time_idx    |
                                        +-----------------------------+

Notes and implications
- The app’s primary read dimension is chat_room ordered by time. Modeling the primary table by name/time is a DynamoDB compromise to support multiple access patterns using a GSI. In ScyllaDB, we should model for the dominant read path (room/time) directly.
- The time attribute is a microsecond-resolution Unix timestamp in a string. DynamoDB stores it lexicographically; the code relies on string ordering matching numeric ordering due to identical length formatting from Python’s datetime.timestamp().

1.2 ScyllaDB data model differences and mapping

Core differences
- ScyllaDB (and Apache Cassandra) use keyspace/table/partition/clustered rows; secondary indexes and materialized views exist, but the fundamental best practice is to model one table per primary query pattern.
- Pagination is handled by the driver using page_size and paging_state instead of LastEvaluatedKey.
- Conditional writes use Lightweight Transactions (LWT) with IF conditions (e.g., IF NOT EXISTS). LWT has a cost; use it only when needed.
- Timestamps: the timestamp type has millisecond precision. For microseconds, store as bigint or use timeuuid (monotonic-ish ordering, uniqueness).

Mapping strategy options
- Option A (recommended): Base table keyed by chat_room and time, plus a materialized view (or second table) keyed by user/time if user queries are needed.
- Option B (drop-in approach): Use Scylla Alternator (DynamoDB-compatible API). Keep boto3 and Dynamo query shapes intact; run against Scylla. This minimizes app code changes at the expense of being tied to the Alternator API.

We proceed with Option A as the primary plan (native CQL), and document Option B as an alternative path.

1.3 Proposed ScyllaDB schema (Option A: native CQL)

Goals
- Optimize for the dominant read: messages by chat_room ordered by time (latest-first)
- Preserve ability to query by user (optional) without impacting the critical path
- Maintain deduplication semantics of DynamoDB’s conditional put
- Keep pagination and differential updates efficient

Key design choices
- Base table: chat_by_room with partition key on chat_room and clustering on time (DESC) and name
- Optional bucketing by day to bound partition size (recommended at scale)
- Optional materialized view chat_by_user to support per-user timelines, or use dual-writes into a second table if you prefer to avoid MVs
- Store time as bigint micros to preserve original precision, or as timeuuid for monotonic uniqueness. We choose bigint for clarity and exact mapping.

Schema without bucketing (simpler to start)

CREATE KEYSPACE IF NOT EXISTS chat_app
  WITH replication = {
    'class': 'NetworkTopologyStrategy',
    'replication_factor': '3'
  };

-- Base table optimized for the main read pattern
CREATE TABLE IF NOT EXISTS chat_app.chat_by_room (
  chat_room text,
  time_us bigint,      -- microsecond Unix timestamp
  name text,
  comment text,
  PRIMARY KEY ((chat_room), time_us, name)
) WITH CLUSTERING ORDER BY (time_us DESC, name ASC);

-- Optional materialized view for user timelines
CREATE MATERIALIZED VIEW IF NOT EXISTS chat_app.chat_by_user AS
  SELECT chat_room, time_us, name, comment
  FROM chat_app.chat_by_room
  WHERE chat_room IS NOT NULL
    AND time_us IS NOT NULL
    AND name IS NOT NULL
  PRIMARY KEY ((name), time_us, chat_room);

Notes
- Ordering: Defining time_us DESC ensures latest-first without extra ORDER BY.
- Uniqueness: The primary key ((chat_room), time_us, name) prevents two rows with the same time_us/name in a room. If a user posts multiple messages with the exact same microsecond, name disambiguates at clustering-level; if necessary, add an extra tie-breaker (e.g., uuid) as a final clustering column.
- IF NOT EXISTS on INSERT provides dedup similar to Dynamo’s condition expression.

Schema with daily buckets (scale-friendly)

CREATE TABLE IF NOT EXISTS chat_app.chat_by_room_daily (
  chat_room text,
  bucket_date date,    -- e.g., date of message in UTC
  time_us bigint,
  name text,
  comment text,
  PRIMARY KEY ((chat_room, bucket_date), time_us, name)
) WITH CLUSTERING ORDER BY (time_us DESC, name ASC);

CREATE MATERIALIZED VIEW IF NOT EXISTS chat_app.chat_by_user_daily AS
  SELECT chat_room, bucket_date, time_us, name, comment
  FROM chat_app.chat_by_room_daily
  WHERE chat_room IS NOT NULL AND bucket_date IS NOT NULL
    AND time_us IS NOT NULL AND name IS NOT NULL
  PRIMARY KEY ((name, bucket_date), time_us, chat_room);

Trade-offs
- Daily buckets keep partitions bounded and reduce hot partition risk in very active rooms. The application must compute bucket_date from timestamp and may need to query today and one previous bucket when crossing midnight.
- If you do not expect high write rates per room, you can start without buckets and migrate later if needed.


2. Benefits Analysis

Cost
- DynamoDB: On-demand/provisioned RCU/WCU billing with managed operations. Costs scale with request volume; cross-region/global tables add cost.
- ScyllaDB: Runs on your own infrastructure or Scylla Cloud. You pay for nodes/VMs and storage, not per-request. At sustained high throughput, Scylla can be significantly cheaper.

Performance and latency
- ScyllaDB’s shard-per-core architecture and fully asynchronous IO deliver low p99 latencies at high QPS. Time-series patterns (append-mostly with time-ordered clustering) are ideal workloads.
- Read-after-write: With appropriate consistency levels (e.g., QUORUM), you can obtain deterministic read-after-write semantics.

Scalability
- Horizontal scaling by adding nodes; automatic sharding by partition key. Wide partitions are supported but should be bounded; bucketing helps.

Operational complexity
- DynamoDB is fully managed; minimal ops burden.
- ScyllaDB requires operating a cluster (or using Scylla Cloud). You manage replication, topology, upgrades, and monitoring.

Honest assessment for this use case
- For an educational demo and small chat app, DynamoDB might be simpler and sufficient.
- If you intend to scale to high write/read volumes or want to optimize cost at scale, ScyllaDB is a strong fit. The room-by-time access pattern maps cleanly to Scylla.

GSI vs Materialized View performance
- DynamoDB GSI: Writes are eventually replicated to GSI; read paths are highly optimized by the service.
- ScyllaDB MV: Asynchronously maintained by Scylla; reads are native partition lookups. MV maintenance adds write amplification but keeps reads fast. If you need stronger guarantees or want more control, dual-write to a second table instead of MV.


3. Schema Migration Strategy

Target schema (no bucket variant used below for simplicity)

CREATE KEYSPACE IF NOT EXISTS chat_app
  WITH replication = {
    'class': 'NetworkTopologyStrategy',
    'replication_factor': '3'
  };

CREATE TABLE IF NOT EXISTS chat_app.chat_by_room (
  chat_room text,
  time_us bigint,
  name text,
  comment text,
  PRIMARY KEY ((chat_room), time_us, name)
) WITH CLUSTERING ORDER BY (time_us DESC, name ASC)
  AND compaction = {'class': 'TimeWindowCompactionStrategy', 'compaction_window_unit': 'DAYS', 'compaction_window_size': '1'};

-- Optional for user queries
CREATE MATERIALIZED VIEW IF NOT EXISTS chat_app.chat_by_user AS
  SELECT chat_room, time_us, name, comment
  FROM chat_app.chat_by_room
  WHERE chat_room IS NOT NULL AND time_us IS NOT NULL AND name IS NOT NULL
  PRIMARY KEY ((name), time_us, chat_room);

Notes on mapping
- DynamoDB (name, time) → Optional MV primary key ((name), time_us). We store time as bigint microseconds for exact mapping.
- DynamoDB GSI (chat_room, time) → Scylla base table ((chat_room), time_us).
- Conditional writes: Use INSERT ... IF NOT EXISTS to prevent duplicates for the same primary key. Consider whether you truly need LWT; if the generating timestamp ensures uniqueness, you can avoid LWT for better throughput.


4. Query Migration Plan

This section maps each DdbChat method to equivalent CQL and driver usage. Current implementations are in <ref_snippet file="/home/ubuntu/repos/amazon-dynamodb-chat-sample/chalicelib/ddb.py" lines="24-115" />.

Driver choice
- Use the DataStax cassandra-driver (works with ScyllaDB). Install via pip install cassandra-driver.

4.1 putComment

Current DynamoDB
- table.put_item(Item={name, time, comment, chat_room}, ConditionExpression=attribute_not_exists(time) AND attribute_not_exists(name))

Equivalent Scylla
CQL (single-table base + MV):
INSERT INTO chat_app.chat_by_room (chat_room, time_us, name, comment)
VALUES (?, ?, ?, ?) IF NOT EXISTS;

Python example
from cassandra.cluster import Cluster
from cassandra.query import SimpleStatement

cluster = Cluster(["127.0.0.1"])  # or Scylla contact points
session = cluster.connect("chat_app")

stmt = session.prepare(
    "INSERT INTO chat_by_room (chat_room, time_us, name, comment) VALUES (?, ?, ?, ?) IF NOT EXISTS"
)
result = session.execute(stmt, (chat_room, time_us, name, comment))

applied = result[0].applied  # True if inserted, False if duplicate

Notes
- LWT (IF NOT EXISTS) provides the same no-duplicate guarantee as DynamoDB’s conditional expression. Be aware of the LWT cost under high write rates; if acceptable, keep it. Otherwise, ensure time_us uniqueness by generating a tie-breaker (e.g., adding a per-message UUID as a final clustering column) and drop LWT.

4.2 getLatestComments

Current DynamoDB
- Query GSI chat_room_time_idx with KeyCondition on chat_room, ScanIndexForward=False, Limit=N.

Equivalent Scylla
CQL
SELECT chat_room, time_us, name, comment
FROM chat_app.chat_by_room
WHERE chat_room = ?
LIMIT ?;

Because the clustering order is DESC on time_us, the first rows are the latest messages.

Python example
stmt = session.prepare(
    "SELECT chat_room, time_us, name, comment FROM chat_by_room WHERE chat_room = ? LIMIT ?"
)
rows = session.execute(stmt, (chat_room, limit))

4.3 getRangeComments (differential since timestamp)

Current DynamoDB
- Query GSI where chat_room = X AND time > position; ScanIndexForward=False; paginate with LastEvaluatedKey

Equivalent Scylla
CQL
SELECT chat_room, time_us, name, comment
FROM chat_app.chat_by_room
WHERE chat_room = ? AND time_us > ?;

If you need latest-first ordering, either:
- Keep clustering DESC and invert predicate to time_us >= lower_bound and page forward (clients can reverse), or
- Query with time_us > ? and reverse in application if necessary.

Python with paging
statement = session.prepare(
    "SELECT chat_room, time_us, name, comment FROM chat_by_room WHERE chat_room = ? AND time_us > ?"
)
statement.fetch_size = 500  # page size
result = session.execute(statement, (chat_room, position_time_us))
for row in result.current_rows:
    process(row)
while result.has_more_pages:
    result = session.execute(statement, (chat_room, position_time_us), paging_state=result.paging_state)
    for row in result.current_rows:
        process(row)

Notes
- Scylla paging uses fetch_size and paging_state. Expose paging_state as a base64 string to clients if you want Dynamo-like continuation tokens.

4.4 getAllComments

Current DynamoDB
- Query all GSI rows for chat_room with pagination until exhausted

Equivalent Scylla
CQL
SELECT chat_room, time_us, name, comment
FROM chat_app.chat_by_room
WHERE chat_room = ?;

Use the same paging approach as above; iterate pages until has_more_pages is False.

Behavior differences and limitations
- ORDER BY: With DESC clustering, results are already newest-first for latest queries. For range queries, you may need to reverse in application or choose ASC clustering and order accordingly; we recommend DESC to avoid ORDER BY costs.
- Time precision: Dynamo stored microseconds as string. Scylla stores microseconds as bigint; ensure consistent conversion at the API boundary.


5. Backwards Compatibility Strategy

Goals
- Zero downtime, safe cutover, and easy rollback.

Plan
1) Provision ScyllaDB and create schemas.
2) Backfill historical data from DynamoDB into Scylla.
   - Option 1: Onetime batch job (e.g., Python script using boto3 to scan GSI by room and write into Scylla).
   - Option 2: Streaming with DynamoDB Streams -> Lambda -> Scylla for near-real-time sync.
3) Implement dual-write in the application behind a feature flag (DB_BACKEND= dynamodb | scylla | dual):
   - On comment add: write to Dynamo and to Scylla (LOGGED BATCH for base+MV not needed; Scylla handles MV. If using dual-table (no MV), use a small LOGGED BATCH for the two tables in Scylla.)
4) Shadow-read validation: Keep serving reads from Dynamo; in background, also read the same queries from Scylla and compare counts/hashes for a sample of requests. Emit metrics.
5) Cutover reads per endpoint behind the flag to Scylla when parity confirmed.
6) Monitor and stabilize. Keep dual-writes for a cooldown period.
7) Disable Dynamo reads; optionally stop dual-writes and decommission Dynamo after a final retention period.

Rollback
- If issues occur after cutover, flip the flag to read from Dynamo immediately. With dual-writes still active, data remains consistent in both systems.

Environment-aware connection logic
- Extend create_connection() pattern to a factory that returns either a Dynamo client (boto3), a Scylla client (cassandra-driver session), or a dual wrapper. Controlled by env var DB_BACKEND and connection parameters (e.g., SCYLLA_CONTACT_POINTS, KEYSPACE).


6. Implementation Roadmap

Phase 0: Planning and provisioning
- Decide on schema variant (with or without buckets). Start without buckets unless you expect hot room partitions.
- Provision ScyllaDB (self-managed cluster or Scylla Cloud). Obtain contact points and credentials.

Phase 1: Schema and client library
- Create keyspace and tables (and MV if used).
- Add a new Scylla client module, e.g., chalicelib/scylla_chat.py, mirroring DdbChat’s interface: put_comment, get_latest_comments, get_range_comments, get_all_comments.
- Introduce a small abstraction in app.py to select backend based on env: DB_BACKEND and related config. For dual mode, insert to both; on reads, select one or both depending on rollout stage.

Files to modify
- app.py: Select backend and wire routes to new client. <ref_file file="/home/ubuntu/repos/amazon-dynamodb-chat-sample/app.py" />
- chalicelib/ddb.py: Keep as-is for Dynamo path. <ref_file file="/home/ubuntu/repos/amazon-dynamodb-chat-sample/chalicelib/ddb.py" />
- chalicelib/scylla_chat.py: New module implementing the Scylla equivalents (native CQL or Alternator path).
- tests/: Parameterize tests to run against both backends; add dockerized Scylla for CI.
- .chalice/config.json: Add new environment variables for DB_BACKEND and Scylla contact points by stage.

Phase 2: Backfill
- Write a backfill script to migrate existing data from Dynamo GSI to Scylla chat_by_room.
  - Enumerate chat rooms (scan GSI for distinct chat_room or maintain a separate list if available).
  - For each room, paginate through all items and write to Scylla using prepared statements with an appropriate concurrency.
- Validate counts per room and sample content hashes.

Phase 3: Dual-write and shadow-read
- Enable dual-write on comment add.
- Keep reads on Dynamo; perform out-of-band shadow reads from Scylla to compare results.

Phase 4: Cutover reads
- Flip read endpoints to Scylla. Keep dual-writes for a cooldown period.
- Monitor latency, error rates, and data consistency.

Phase 5: Decommission
- After the retention window, disable dual-writes and remove Dynamo dependencies (optional).

Local development and CI
- Provide a docker-compose service for Scylla (or use scylla in CI) and a pytest marker to run tests under Scylla. Maintain DynamoDB Local for Dynamo tests to avoid breaking existing flows during transition.


7. Performance Optimization Considerations

Compaction strategy
- Use TimeWindowCompactionStrategy (TWCS) for time-series workloads; set a 1-day window to group SSTables by time and improve read performance for recent data.

Consistency levels
- For low-latency writes with eventual consistency, use CL = ONE.
- For read-after-write on the same room and low tolerance for stale reads, consider QUORUM for reads/writes.

Prepared statements and connection pooling
- Always use prepared statements for hot queries; enable token-aware and speculative execution policies in the driver for low latency.

Polling pattern
- The frontend polls every 3 seconds. Scylla does not provide push; consider alternatives like WebSocket or Server-Sent Events to push updates, reducing DB load. If keeping polling, the time_us > last_seen pattern is efficient.

Partition sizing and hotspots
- A very active chat_room can create a hot partition. If you observe sustained high write rates, migrate to the daily-bucket schema ((chat_room, bucket_date), ...). For global chat rooms, you can also add a random sub-partition key (e.g., shard number) and scatter/gather at read time, but that complicates reads.

Time precision
- Dynamo uses microseconds; Scylla timestamp is milliseconds. We chose bigint time_us to preserve microseconds. If you switch to timeuuid, you get uniqueness and ordering but must adapt the client code for range queries (use timeuuid functions like minTimeuuid/maxTimeuuid for bounds).

Materialized views vs dual-table writes
- MVs simplify write code but add background maintenance. If you need strict control, write to two tables in a LOGGED BATCH. For this app, MV suffices since the main path is chat_by_room, and user timeline is secondary.

Alternator (DynamoDB-compatible API)
- Scylla Alternator allows you to keep the DynamoDB API (boto3 calls, table/index definitions) with Scylla as the backend. This can dramatically reduce application changes. Caveats: operational maturity and feature parity depend on your Scylla version and Alternator configuration. If speed-to-migrate is top priority, consider Alternator as Option B.


8. Testing Strategy

Unit and integration tests
- Mirror existing tests to run against the Scylla backend. Parametrize fixtures to instantiate either DdbChat (Dynamo) or ScyllaChat (Scylla) based on a pytest marker or env var.
- For Scylla, spin up scylla in Docker for tests; create keyspace/table before tests and drop after.

Dual-database operation tests
- In dual mode, assert that writes land in both backends. Add a small helper to fetch from both and compare payloads.

Pagination and differential tests
- Verify paging by limiting fetch_size and walking through paging_state until exhaustion; ensure deterministic ordering given DESC clustering.

Performance benchmarking
- Use k6 or Locust to hammer /chat/comments/latest and /chat/comments/latest/{latest_seq_id}. Measure p50/p95/p99 latency and throughput for increasing QPS. Compare Dynamo vs Scylla under similar load. Validate that LWT (IF NOT EXISTS) costs are acceptable; if not, introduce a UUID tie-breaker and remove LWT.


Appendix: End-to-end example code (Scylla client)

from cassandra.cluster import Cluster
from cassandra.query import PreparedStatement

class ScyllaChat:
    def __init__(self, contact_points, keyspace="chat_app"):
        self.cluster = Cluster(contact_points)
        self.session = self.cluster.connect(keyspace)
        self._prep()

    def _prep(self):
        self.stmt_insert = self.session.prepare(
            "INSERT INTO chat_by_room (chat_room, time_us, name, comment) VALUES (?, ?, ?, ?) IF NOT EXISTS"
        )
        self.stmt_latest = self.session.prepare(
            "SELECT chat_room, time_us, name, comment FROM chat_by_room WHERE chat_room = ? LIMIT ?"
        )
        self.stmt_range = self.session.prepare(
            "SELECT chat_room, time_us, name, comment FROM chat_by_room WHERE chat_room = ? AND time_us > ?"
        )
        self.stmt_all = self.session.prepare(
            "SELECT chat_room, time_us, name, comment FROM chat_by_room WHERE chat_room = ?"
        )

    def put_comment(self, name, comment, chat_room):
        import time
        time_us = int(time.time() * 1_000_000)
        res = self.session.execute(self.stmt_insert, (chat_room, time_us, name, comment))
        return {"applied": res[0].applied, "time": time_us}

    def get_latest_comments(self, chat_room, limit):
        rows = self.session.execute(self.stmt_latest, (chat_room, limit))
        return list(rows)

    def get_range_comments(self, chat_room, position_us):
        rows = self.session.execute(self.stmt_range, (chat_room, position_us))
        return list(rows)

    def get_all_comments(self, chat_room):
        rows = self.session.execute(self.stmt_all, (chat_room,))
        return list(rows)


Appendix: Option B (Alternator) quick path

- Run Scylla Alternator and point boto3 to the Alternator endpoint.
- Recreate the chat table and GSI using the same schema as Dynamo.
- Minimal app code change: adjust create_connection() to use Alternator endpoint when DB_BACKEND=scylla-alternator.
- Validate parity and cut over DNS/endpoint configuration.


Checklist for execution
- [ ] Provision Scylla and create keyspace/tables (and MV if needed)
- [ ] Implement ScyllaChat client and backend selection in app.py
- [ ] Write and run backfill from Dynamo to Scylla
- [ ] Enable dual-writes, shadow reads, and parity checks
- [ ] Flip read routes to Scylla and monitor
- [ ] Disable dual-writes and decommission Dynamo (optional)

End of document.
