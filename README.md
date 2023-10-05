# Performance Experiment

Try to make this run faster. Requires SQL Server 2019 (V15) or newer. To test it, run the PerformanceExperiment-V1.sql script. (Takes a couple minutes.) And then run the following statements in 5 query windows so that they all run at the same time. (Takes a minute.)

		use [PerformanceExperiment];
		exec [dbo].[p_RunProcessMessages];

Once they're all done, run the following to check the results.

		use [PerformanceExperiment];
		exec [dbo].[p_PerformanceReport];

  The most important column is K_Rows_Per_Sec.

# The Challenge
After that, make improvements and repeat the process. You can change procs, indexing, isolation levels, and such. But there are limits:
* Don't change the columns.
* The insert and update must remain in a transaction together.

# What the code does
The code transfers rows from staging to transaction. The transfered rows get timestamped in staging to mark them as complete. It's intended to imitate a common concurrent execution situation. The insert and update are in a transaction together so that they either both succeed or both roll back. Each session claims a user and only works on that user. So one session does not touch the rows that are for another user.

```mermaid
	graph BT;
	b[Staging] --> u[User]
	c[Transaction] --> u[User]
	d[ExecutionLog] --> u[User]
	a[AppSetting];
```

# Change ideas
The performance of this scenario is typically improved by partitioning tables by user. That's because such partitioning prevents locks for one user from blocking any other users. But there are many other factors that affect performance with or without partitioning. You might try some of the following.
- Partition staging and transaction tables on user.
- Process more or fewer rows per loop.
- Select the rows to move into a temp table.
- Put that select inside or outside of the transaction.
- Use user as the first column in the clustered index.
- Force table or row level locking with table hints.
- Use a different transaction isolation level. (Try READ COMMITTED SNAPSHOT).
- Use OPTIMIZE_FOR_SEQUENTIAL_KEY.

# Objects
### Setting Table
This table gives you control over arbitrary values used in the code. 
- NUMBER OF USERS - Typically 5. This is the number of users created. The fake staging data is distributed amung this number of users.
- RUN SECONDS LIMIT - Typically, 60. The [p_RunProcessTransactions] proc stops processing at that time limit.
- SECONDS BETWEEN RUNS - Typically, 100. It's how [p_PerformanceReport] distinguishes one run from another. It's the time between the start of 2 runs. So it should be greater than RUN SECONDS LIMIT.
- PROCESS TRANSACTIONS ROW COUNT - Typically, 1000 to 10,000. It's the number of rows processed each time [p_ProcessTransactions] is called. Locks are usually at the page level. A page can hold 50 rows in the Staging table. Setting this to 250 thousand would cause locks on 5000 pages. And that would escelate locks to the table level. The tradeoff is managing fewer locks means blocking other sessions more. 

### User Table
This table is primarrilly for reserving a user for a session. The [p_RunProcessTransactions] proc sets the IsProcessing value for a user. UserID is a foreign key in 3 other tables:
- Staging
- Transaction
- ExecutionLog

### Staging Table
This table gets loaded with fake data just so that there's something to transfer. In the [p_RunProcessTransactions] proc, it gets selected and updated. The update sets the ProcessedDate for the rows that have been transfered.

### Transaction Table
This table on



