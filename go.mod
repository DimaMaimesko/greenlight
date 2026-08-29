module github.com/DimaMaimesko/greenlight

go 1.26.5

require (
	github.com/joho/godotenv v1.5.1
	github.com/julienschmidt/httprouter v1.3.0
	github.com/lib/pq v1.12.3
	github.com/tomasen/realip v0.0.0-20180522021738-f0c99a92ddce
	github.com/wneessen/go-mail v0.8.1
	golang.org/x/crypto v0.55.0
	golang.org/x/time v0.15.0
)

require (
	github.com/BurntSushi/toml v1.4.1-0.20240526193622-a339e1f7089c // indirect
	golang.org/x/exp/typeparams v0.0.0-20231108232855-2478ac86f678 // indirect
	golang.org/x/mod v0.39.0 // indirect
	golang.org/x/sync v0.22.0 // indirect
	golang.org/x/text v0.41.0 // indirect
	golang.org/x/tools v0.49.0 // indirect
	honnef.co/go/tools v0.8.1 // indirect
)

tool honnef.co/go/tools/cmd/staticcheck
