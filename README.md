# Performance Experiment

Try to make this run faster. Requires SQL Server 2019 (V15). To test it, run this script. (Takes a couple minutes.) And then run the following statement in 5 query windows so that they all run at the same time. (Takes a minute.)

		use [PerformanceExperiment];
		exec [dbo].[p_RunProcessMessages];

Once they're all done, run the following to check the results.

		use [PerformanceExperiment];
		exec [dbo].[p_PerformanceReport];

## Challenge
After that, make improvements and repeat the process. You can change procs, indexing, isolation levels, and such. But there are limits:
* Don't change the columns.
* The insert and update must be in a transaction together.

## What the code does
The code transferes rows from staging to transaction. But each session is for a different user. So one session does not touch the rows that are for another session. The perpose of this is entirely fictitional. It's intended to imitate a common concurrent execution situation. 



```mermaid
  graph TD;
      A-->B;
      A-->C;
      B-->D;
      C-->D;
```
