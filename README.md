# Performance Experiment

Try to make this run faster and without adding issues like deadlocks.
Change procs, indexing or values. But avoid changing the columns in tables.
Requires SQL Server 2022 (V16).
To test it, run this script. (Takes a couple minutes.)
And then run the following statement in 5 query windows
so that they all run at the same time. (Takes a minute.)

		use [PerformanceExperiment];
		exec [dbo].[p_RunProcessMessages];

Once they're all done, run the following to check the results.

		use [PerformanceExperiment];
		exec [dbo].[p_PerformanceReport];

After that, make some improvements and repeat the process.

