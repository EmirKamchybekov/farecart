-- transfer rules so trip cost can be computed from an itinerary
alter table fares add column if not exists transfer_cents int not null default 0;
alter table fares add column if not exists transfer_window_min int not null default 120;
alter table fares add column if not exists max_transfers int not null default 2;
update fares set transfer_cents = 0, transfer_window_min = 120, max_transfers = 2, effective_on = '2023-02-20'
 where rider in ('full','student');
update fares set transfer_cents = 0, transfer_window_min = 120, max_transfers = 2 where rider = 'reduced_access';
