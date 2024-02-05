USE [PerformanceExperiment];
GO

create or alter proc [dbo].[p_LocksAndBlocks] as;
	/*
		Run this script or this proc while sessions are running.
		It shows locks, blocks, wait times and transaction counts.
		You can also run sp_who2 and sp_lock for more details.

		exec [dbo].[p_LocksAndBlocks];
	*/
	select
		identity(int) as LockID,      -- int
		l.request_session_id as spid, -- int
		p.[object_id],                -- int
		l.resource_associated_entity_id, -- bigint
		p.index_id,                   -- int
		p.partition_number,           -- int
		l.resource_type as [type],    -- nvarchar(60)
		l.request_mode as mode,       -- nvarchar(60)
		l.request_status as [status], -- nvarchar(60)
		format(w.wait_duration_ms / 1000.0, 'N1') as secs, -- nvarchar(4000)
		w.wait_type,                  -- nvarchar(60)
		w.blocking_session_id as blocking_spid -- smallint
	into #lock
	from sys.dm_tran_locks l with (nolock)
	left join sys.partitions p with (nolock) on l.resource_associated_entity_id = p.[partition_id]
	left join sys.dm_os_waiting_tasks w with (nolock) on l.lock_owner_address = w.resource_address
	where resource_database_id = DB_ID()

	update #lock
	set [object_id] = resource_associated_entity_id
	where [type] = 'OBJECT'

	update targt
	set [object_id] = p.[object_id]
	from #lock targt
	join sys.allocation_units au with (nolock) on targt.resource_associated_entity_id = au.allocation_unit_id
	join sys.partitions p with (nolock) on au.container_id = p.[partition_id]
	where targt.[type] = 'ALLOCATION_UNIT';

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
	where l.[type] <> 'DATABASE'
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

