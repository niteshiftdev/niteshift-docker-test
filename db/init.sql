CREATE TABLE IF NOT EXISTS items (
    id INT AUTO_INCREMENT PRIMARY KEY,
    name VARCHAR(255) NOT NULL,
    processed BOOLEAN DEFAULT FALSE,
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);

-- Seed some initial data so the DB isn't empty
INSERT INTO items (name, processed) VALUES
    ('seed-alpha', TRUE),
    ('seed-beta', TRUE),
    ('seed-gamma', FALSE),
    ('seed-delta', FALSE),
    ('seed-epsilon', FALSE);
