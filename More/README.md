# p_LocksAndBlocks.sql
Run this script while an experiment is running to see which locks are held and which sessions are blocked by other sessions. It's like running [sys].[sp_lock] and [sys].[sp_who2] except customized for this project. It might help you figure out how to make your code faster.

- **spid** - session ID. See [sys.dm_tran_locks](https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-views/sys-dm-tran-locks-transact-sql?view=sql-server-ver16) request_session_id for more info.
- **block** - "blocked", "blocking" or both means it's blocked by or blocking another session.
- **table_name**
- **index_id** - 1 means it's the clustered index. NULL means the lock is on the whole table.
- **partition_number** - Only for partitioned tables.
- **type** - resource_type. Get enough PAGE and KEY locks and locking will escalate to OBJECT or HOBT. HOBT is a partition level lock.
- **mode** - See below.
- **status** - Anything other than GRANT means the lock request is blocked by a lock in another session.
- **occurs** - The number of locks that match. KEY and PAGE type locks often have several.
- **blocking_spid** - The spid of the other session that's blocking the requested lock from being granted.
- **secs** - How long the lock request has been waiting.
- **wait_type** - What's causing the block.

## mode column
The key to understanding lock modes is the lock compatability matrix. For example, one session can hold a shared lock on a page while another session is granted an update and vice versa. That's not the case for 2 sessions requesting update locks. One of those sessions will have to wait until the other one completes its transaction. If you see that a lock request is blocked, compare the lock modes of the blocked and blocking locks.

<img width="357" alt="lock-compatibility-matrix" src="https://github.com/chucknewmanjr/PerformanceExperiment/assets/33396894/cf5d2ca9-330d-494a-bc89-0bc214cacfdd">

# PerformanceExperiment-V2-Partitioning.sql
In this version, the [Staging] and [Transaction] tables are partitioned so that each user is in its own partition. There are only 10 partitions. So the number of users is limited to 10. 

# PerformanceExperiment-V3-Play.sql
This version doesn't have partitioning. But it does have some of the other changes listed above. Currently, it has the following:
- READ_COMMITTED_SNAPSHOT

# PerformanceExperiment-V4-Partitioning-Play.sql
This version has partitioning plus some of the other changes listed above. Currently, it has the following:
- READ_COMMITTED_SNAPSHOT
- OPTIMIZE_FOR_SEQUENTIAL_KEY on the ExecutionLog table.

