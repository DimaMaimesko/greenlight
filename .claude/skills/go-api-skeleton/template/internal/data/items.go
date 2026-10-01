package data

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"time"

	"example.com/app/internal/validator"
	"github.com/lib/pq"
)

// Item is the example resource. Copy this file (and cmd/api/items.go) as the
// starting point for a new resource, or delete both once you have your own.
type Item struct {
	ID          int       `json:"id"`
	CreatedAt   time.Time `json:"created_at"`
	Name        string    `json:"name"`
	Description string    `json:"description,omitzero"`
	Tags        []string  `json:"tags"`
	Version     int       `json:"version"`
}

func ValidateItem(v *validator.Validator, item Item) {
	v.Check(item.Name != "", "name", "must be provided")
	v.Check(len(item.Name) <= 500, "name", "must not be more than 500 bytes long")

	v.Check(len(item.Description) <= 5000, "description", "must not be more than 5000 bytes long")

	v.Check(len(item.Tags) <= 5, "tags", "must not contain more than 5 tags")
	v.Check(validator.Unique(item.Tags), "tags", "must not contain duplicate values")
}

// ItemModel wraps a sql.DB connection pool.
type ItemModel struct {
	DB *sql.DB
}

// Insert adds a new record and returns it with the values the database
// generated: id, created_at and version.
func (m ItemModel) Insert(item Item) (Item, error) {
	// The tags column is NOT NULL and pq.Array() writes a nil slice as NULL,
	// so store "no tags" as an empty array.
	if item.Tags == nil {
		item.Tags = []string{}
	}

	query := `
        INSERT INTO items (name, description, tags)
        VALUES ($1, $2, $3)
        RETURNING id, created_at, version`

	args := []any{item.Name, item.Description, pq.Array(item.Tags)}

	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()

	err := m.DB.QueryRowContext(ctx, query, args...).Scan(&item.ID, &item.CreatedAt, &item.Version)
	if err != nil {
		return Item{}, err
	}

	return item, nil
}

func (m ItemModel) Get(id int) (Item, error) {
	if id < 1 {
		return Item{}, ErrRecordNotFound
	}

	query := `
        SELECT id, created_at, name, description, tags, version
        FROM items
        WHERE id = $1`

	var item Item

	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()

	err := m.DB.QueryRowContext(ctx, query, id).Scan(
		&item.ID,
		&item.CreatedAt,
		&item.Name,
		&item.Description,
		pq.Array(&item.Tags),
		&item.Version,
	)
	if err != nil {
		switch {
		case errors.Is(err, sql.ErrNoRows):
			return Item{}, ErrRecordNotFound
		default:
			return Item{}, err
		}
	}

	return item, nil
}

// Update saves the record only if its version still matches the one that was
// read, so two clients can't silently overwrite each other's changes.
func (m ItemModel) Update(item Item) (Item, error) {
	if item.Tags == nil {
		item.Tags = []string{}
	}

	query := `
        UPDATE items
        SET name = $1, description = $2, tags = $3, version = version + 1
        WHERE id = $4 AND version = $5
        RETURNING version`

	args := []any{
		item.Name,
		item.Description,
		pq.Array(item.Tags),
		item.ID,
		item.Version,
	}

	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()

	err := m.DB.QueryRowContext(ctx, query, args...).Scan(&item.Version)
	if err != nil {
		switch {
		case errors.Is(err, sql.ErrNoRows):
			return Item{}, ErrEditConflict
		default:
			return Item{}, err
		}
	}

	return item, nil
}

func (m ItemModel) Delete(id int) error {
	if id < 1 {
		return ErrRecordNotFound
	}

	query := `
        DELETE FROM items
        WHERE id = $1`

	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()

	result, err := m.DB.ExecContext(ctx, query, id)
	if err != nil {
		return err
	}

	rowsAffected, err := result.RowsAffected()
	if err != nil {
		return err
	}

	if rowsAffected == 0 {
		return ErrRecordNotFound
	}

	return nil
}

// GetAll returns one page of items, optionally filtered by a full-text search
// on the name and by tags (an item must have all of them). An empty name or
// tags slice matches everything.
func (m ItemModel) GetAll(name string, tags []string, filters Filters) ([]Item, Metadata, error) {
	// The ORDER BY column can't be a placeholder. sortColumn() only returns
	// values from the safelist, so interpolating it here is safe.
	query := fmt.Sprintf(`
        SELECT count(*) OVER(), id, created_at, name, description, tags, version
        FROM items
        WHERE (to_tsvector('simple', name) @@ plainto_tsquery('simple', $1) OR $1 = '')
        AND (tags @> $2 OR $2 = '{}')
        ORDER BY %s %s, id ASC
        LIMIT $3 OFFSET $4`, filters.sortColumn(), filters.sortDirection())

	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()

	args := []any{name, pq.Array(tags), filters.limit(), filters.offset()}

	rows, err := m.DB.QueryContext(ctx, query, args...)
	if err != nil {
		return nil, Metadata{}, err
	}
	defer rows.Close()

	totalRecords := 0
	items := []Item{}

	for rows.Next() {
		var item Item

		err := rows.Scan(
			&totalRecords,
			&item.ID,
			&item.CreatedAt,
			&item.Name,
			&item.Description,
			pq.Array(&item.Tags),
			&item.Version,
		)
		if err != nil {
			return nil, Metadata{}, err
		}

		items = append(items, item)
	}

	if err = rows.Err(); err != nil {
		return nil, Metadata{}, err
	}

	metadata := calculateMetadata(totalRecords, filters.Page, filters.PageSize)

	return items, metadata, nil
}
