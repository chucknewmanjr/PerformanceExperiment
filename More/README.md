# p_LocksAndBlocks.sql
Run this while an experiment is running to see which locks are held and which sessions are blocked by other sessions. It might help you figure out how to make your code faster.

- spid - session ID or process ID. See [sys.dm_tran_locks](https://learn.microsoft.com/en-us/sql/relational-databases/system-dynamic-management-views/sys-dm-tran-locks-transact-sql?view=sql-server-ver16) request_session_id for more info.
- block - "blocked", "blocking" or both means it's blocked by or blocking another session.
- table_name
- index_id - 1 means it's the clustered index. NULL means the lock is on the whole table.
- partition_number - Only for partitioned tables.
- type - resource_type. 
- mode
- status
- occurs
- blocking_spid
- secs
- wait_time



<img width="357" alt="lock-compatibility-matrix" src="https://github.com/chucknewmanjr/PerformanceExperiment/assets/33396894/cf5d2ca9-330d-494a-bc89-0bc214cacfdd">




