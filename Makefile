create-table:
	migrate create -seq -ext=.sql -dir=./migrations create_movies_table
migrate:
	migrate -path=./migrations -database="postgres://greenlight:pa55word@localhost/greenlight?sslmode=disable" up
check-migration-version:
	migrate -path=./migrations -database="postgres://greenlight:pa55word@localhost/greenlight?sslmode=disable" version
migrate-to-version:
	migrate -path=./migrations -database="postgres://greenlight:pa55word@localhost/greenlight?sslmode=disable" goto 1
migrate-roll-back:
	migrate -path=./migrations -database="postgres://greenlight:pa55word@localhost/greenlight?sslmode=disable" down 1
migrate-down:
	migrate -path=./migrations -database="postgres://greenlight:pa55word@localhost/greenlight?sslmode=disable" down
