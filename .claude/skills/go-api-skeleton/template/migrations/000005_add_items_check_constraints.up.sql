ALTER TABLE items ADD CONSTRAINT items_name_length_check CHECK (octet_length(name) BETWEEN 1 AND 500);

ALTER TABLE items ADD CONSTRAINT items_description_length_check CHECK (octet_length(description) <= 5000);

ALTER TABLE items ADD CONSTRAINT items_tags_length_check CHECK (cardinality(tags) <= 5);
