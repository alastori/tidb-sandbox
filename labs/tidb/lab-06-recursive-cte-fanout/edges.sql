-- Nodes
CREATE TABLE nodes (id INT PRIMARY KEY);

-- Edges (super-node 1 has 5 children; node 2 has 2)
CREATE TABLE edges (
    from_id INT,
    to_id   INT,
    weight  INT,
    PRIMARY KEY (from_id, to_id)
);

INSERT INTO nodes VALUES (1),(2),(10),(11),(12),(13),(14),(20),(21);

INSERT INTO edges VALUES
(1,10,50),(1,11,40),(1,12,30),(1,13,20),(1,14,10),
(2,20,99),(2,21,10);
