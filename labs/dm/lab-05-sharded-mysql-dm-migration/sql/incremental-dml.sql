-- Incremental DML for scenario S2
-- Parameters (set before sourcing):
--   @shard_prefix  — e.g. 'S1', 'S2', 'S3'
--
-- Applies 7 INSERTs, 7 UPDATEs, 7 DELETEs per shard (21 ops total per shard)

USE contact_book;

-- INSERTs: 7 new rows beyond the initial 100K
INSERT INTO contacts (uid, mobile, name, region) VALUES
    (CONCAT(@shard_prefix, '-NEW-0001'), '+1-555-9990001', CONCAT('New-', @shard_prefix, '-1'), 'US-EAST'),
    (CONCAT(@shard_prefix, '-NEW-0002'), '+1-555-9990002', CONCAT('New-', @shard_prefix, '-2'), 'US-WEST'),
    (CONCAT(@shard_prefix, '-NEW-0003'), '+1-555-9990003', CONCAT('New-', @shard_prefix, '-3'), 'EU'),
    (CONCAT(@shard_prefix, '-NEW-0004'), '+1-555-9990004', CONCAT('New-', @shard_prefix, '-4'), 'APAC'),
    (CONCAT(@shard_prefix, '-NEW-0005'), '+1-555-9990005', CONCAT('New-', @shard_prefix, '-5'), 'LATAM'),
    (CONCAT(@shard_prefix, '-NEW-0006'), '+1-555-9990006', CONCAT('New-', @shard_prefix, '-6'), 'US-EAST'),
    (CONCAT(@shard_prefix, '-NEW-0007'), '+1-555-9990007', CONCAT('New-', @shard_prefix, '-7'), 'US-WEST');

-- UPDATEs: modify region for 7 existing rows
UPDATE contacts SET region = 'UPDATED' WHERE uid = CONCAT(@shard_prefix, '-0000010');
UPDATE contacts SET region = 'UPDATED' WHERE uid = CONCAT(@shard_prefix, '-0000020');
UPDATE contacts SET region = 'UPDATED' WHERE uid = CONCAT(@shard_prefix, '-0000030');
UPDATE contacts SET region = 'UPDATED' WHERE uid = CONCAT(@shard_prefix, '-0000040');
UPDATE contacts SET region = 'UPDATED' WHERE uid = CONCAT(@shard_prefix, '-0000050');
UPDATE contacts SET region = 'UPDATED' WHERE uid = CONCAT(@shard_prefix, '-0000060');
UPDATE contacts SET region = 'UPDATED' WHERE uid = CONCAT(@shard_prefix, '-0000070');

-- DELETEs: remove 7 existing rows
DELETE FROM contacts WHERE uid = CONCAT(@shard_prefix, '-0000091');
DELETE FROM contacts WHERE uid = CONCAT(@shard_prefix, '-0000092');
DELETE FROM contacts WHERE uid = CONCAT(@shard_prefix, '-0000093');
DELETE FROM contacts WHERE uid = CONCAT(@shard_prefix, '-0000094');
DELETE FROM contacts WHERE uid = CONCAT(@shard_prefix, '-0000095');
DELETE FROM contacts WHERE uid = CONCAT(@shard_prefix, '-0000096');
DELETE FROM contacts WHERE uid = CONCAT(@shard_prefix, '-0000097');
