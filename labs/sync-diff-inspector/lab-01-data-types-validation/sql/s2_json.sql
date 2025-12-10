-- S2: JSON compare correctness
-- Validate JSON comparison with objects, arrays, nested structures, UTF-8

DROP TABLE IF EXISTS s2_json_test;

CREATE TABLE s2_json_test (
    id INT PRIMARY KEY AUTO_INCREMENT,
    json_col JSON,
    description VARCHAR(100)
);

INSERT INTO s2_json_test (json_col, description) VALUES
    ('{}', 'Empty object'),
    ('[]', 'Empty array'),
    ('null', 'JSON null'),
    ('"simple string"', 'JSON string'),
    ('123', 'JSON number'),
    ('true', 'JSON boolean'),
    ('{"name": "John", "age": 30}', 'Simple object'),
    ('{"name": "李明", "city": "北京"}', 'Object with UTF-8'),
    ('[1, 2, 3, 4, 5]', 'Simple array'),
    ('["apple", "banana", "cherry"]', 'String array'),
    ('{"user": {"name": "Alice", "address": {"city": "NYC", "zip": "10001"}}}', 'Nested object'),
    ('[{"id": 1, "name": "A"}, {"id": 2, "name": "B"}]', 'Array of objects'),
    ('{"tags": ["json", "test", "sync-diff"], "count": 3}', 'Mixed types'),
    ('{"a": 1, "b": 2}', 'Object key order test 1'),
    ('{"b": 2, "a": 1}', 'Object key order test 2'),
    (NULL, 'NULL value (not JSON null)');
