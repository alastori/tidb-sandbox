-- S2: Continuous writes - post-syncpoint data (should NOT appear in snapshot comparison)
USE syncpoint_lab;

INSERT INTO t2 (batch, data) VALUES
    (2, 'post-syncpoint-row-1'),
    (2, 'post-syncpoint-row-2'),
    (2, 'post-syncpoint-row-3');
