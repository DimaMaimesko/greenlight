package main

import (
	"expvar"
	"net/http"

	"github.com/julienschmidt/httprouter"
)

func (app *application) routes() http.Handler {
	router := httprouter.New()

	// Send JSON, not httprouter's plain-text defaults, for unknown routes and
	// unsupported methods.
	router.NotFound = http.HandlerFunc(app.notFoundResponse)
	router.MethodNotAllowed = http.HandlerFunc(app.methodNotAllowedResponse)

	router.HandlerFunc(http.MethodGet, "/v1/healthcheck", app.healthcheckHandler)

	router.HandlerFunc(http.MethodGet, "/v1/items", app.requireActivatedUserWithPermission("items:read", app.listItemsHandler))
	router.HandlerFunc(http.MethodPost, "/v1/items", app.requireActivatedUserWithPermission("items:write", app.createItemHandler))
	router.HandlerFunc(http.MethodGet, "/v1/items/:id", app.requireActivatedUserWithPermission("items:read", app.showItemHandler))
	router.HandlerFunc(http.MethodPatch, "/v1/items/:id", app.requireActivatedUserWithPermission("items:write", app.updateItemHandler))
	router.HandlerFunc(http.MethodDelete, "/v1/items/:id", app.requireActivatedUserWithPermission("items:write", app.deleteItemHandler))

	router.HandlerFunc(http.MethodPost, "/v1/users", app.registerUserHandler)
	router.HandlerFunc(http.MethodPut, "/v1/users/activated", app.activateUserHandler)

	router.HandlerFunc(http.MethodPost, "/v1/tokens/authentication", app.createAuthenticationTokenHandler)

	// Open to anyone: block it at the reverse proxy or put it behind auth in
	// production.
	router.Handler(http.MethodGet, "/debug/vars", expvar.Handler())

	// Outermost first: metrics sees every request, recoverPanic covers every
	// layer below it, CORS headers are set even on 429s, and rate-limited
	// requests never reach the database lookup in authenticate.
	return app.metrics(app.recoverPanic(app.enableCORS(app.rateLimit(app.authenticate(router)))))
}
