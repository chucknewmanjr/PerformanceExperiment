USE [PerformanceExperiment];
GO

create or alter proc [dbo].[p_LocksAndBlocks] as;
	/*
		Run this script or this proc while sessions are running.
		It shows locks, blocks, wait times and transaction counts.
		The wait times are in milliseconds.
		You can also run sp_who2 and sp_lock for more details.

		exec [dbo].[p_LocksAndBlocks];
	*/
	select
		identity(int) as LockID,
		l.request_session_id as spid,
		isnull(cast(p.[object_id] as bigint), l.resource_associated_entity_id) as [object_id], 
		p.index_id,
		p.partition_number,
		l.resource_type as [type],
		l.request_mode as mode,
		l.request_status as [status],
		cast(round(w.wait_duration_ms / 1000.0, 1) as real) as secs,
		w.wait_type,
		w.blocking_session_id as blocking_spid
	into #lock
	from sys.dm_tran_locks l with (nolock)
	left join sys.allocation_units a with (nolock)
		on l.resource_associated_entity_id = a.allocation_unit_id
	left join sys.partitions p with (nolock)
		on l.resource_associated_entity_id = p.[partition_id]
		or a.container_id = p.[partition_id]
	left join sys.dm_os_waiting_tasks w with (nolock)
		on l.lock_owner_address = w.resource_address
	where resource_database_id = DB_ID()

	select 
		l.spid, 
		case
			when l.blocking_spid is null and bl.spid is null then ''
			when l.blocking_spid is null then 'blocker'
			when bl.spid is null then 'blocked'
			else 'both blocker and blocked'
		end as [block],
		OBJECT_SCHEMA_NAME(l.[object_id]) + '.' + OBJECT_NAME(l.[object_id]) as table_name, 
		l.index_id, 
		l.partition_number, 
		l.[type], 
		l.mode, 
		l.[status], 
		COUNT(*) as occurs,
		l.blocking_spid,
		l.secs,
		l.wait_type
	from #lock l
	left join #lock bl
		on exists (
			select l.spid, l.[object_id], l.index_id, l.partition_number, l.[type]
			intersect
			select bl.blocking_spid, bl.[object_id], bl.index_id, bl.partition_number, bl.[type]
		)
	where OBJECT_NAME(l.[object_id]) is not null
	group by 
		l.spid, 
		l.[object_id], 
		l.index_id, 
		l.partition_number, 
		l.[type], 
		l.mode, 
		l.[status],
		l.blocking_spid, 
		l.secs,
		l.wait_type,
		bl.spid
	order by 
		l.spid, 
		l.[object_id], 
		l.index_id, 
		l.partition_number, 
		l.[type], 
		l.mode, 
		l.[status];
go

exec [dbo].[p_LocksAndBlocks];

