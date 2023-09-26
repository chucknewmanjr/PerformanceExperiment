# Performance Experiment

Try to make this run faster. Requires SQL Server 2019 (V15) or newer. To test it, run this script. (Takes a couple minutes.) And then run the following statement in 5 query windows so that they all run at the same time. (Takes a minute.)

		use [PerformanceExperiment];
		exec [dbo].[p_RunProcessMessages];

Once they're all done, run the following to check the results.

		use [PerformanceExperiment];
		exec [dbo].[p_PerformanceReport];

# The Challenge
After that, make improvements and repeat the process. You can change procs, indexing, isolation levels, and such. But there are limits:
* Don't change the columns.
* The insert and update must remain in a transaction together.

# What the code does
The code transfers rows from staging to transaction. But each session is for a different user. So one session does not touch the rows that are for another session. The purpose of this is entirely fictional. It's intended to imitate a common concurrent execution situation. After it transfers some rows, it updates those rows in staging so that they don't get transferred again. That insert and update are together in a transaction.

```mermaid
	graph BT;
	b[Staging] --> u[User]
	c[Transaction] --> u[User]
	d[ExecutionLog] --> u[User]
	a[AppSetting];
```

# Change ideas
To improve performance, you might try some of the following.
- Process fewer rows per loop.
- Move the select statement out of the transaction.
- Use table hints to change the locking.
- Use a different transaction isolation level. (Try READ COMMITTED SNAPSHOT).
- Use a table partition on all the tables with a UserID.
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



