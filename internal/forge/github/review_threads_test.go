package github

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"testing"

	"github.com/fullsend-ai/fullsend/internal/forge"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestListPullRequestReviewThreads(t *testing.T) {
	line := 17
	originalLine := 16
	var request map[string]any
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		require.Equal(t, http.MethodPost, r.Method)
		require.Equal(t, "/graphql", r.URL.Path)
		require.Equal(t, "Bearer test-token", r.Header.Get("Authorization"))
		require.NoError(t, json.NewDecoder(r.Body).Decode(&request))
		json.NewEncoder(w).Encode(map[string]any{
			"data": map[string]any{
				"repository": map[string]any{
					"pullRequest": map[string]any{
						"reviewThreads": map[string]any{
							"pageInfo": map[string]any{"hasNextPage": false, "endCursor": ""},
							"nodes": []any{
								map[string]any{
									"id": "PRRT_1", "isResolved": true, "path": "main.go",
									"line": line, "originalLine": originalLine,
									"resolvedBy": map[string]any{"login": "reviewer", "__typename": "User"},
									"comments": map[string]any{
										"pageInfo": map[string]any{"hasNextPage": true},
										"nodes": []any{map[string]any{
											"author": map[string]any{"login": "reviewer", "__typename": "User"},
											"body":   "please update this", "createdAt": "2026-10-04T10:00:00Z",
										}},
									},
								},
								map[string]any{
									"id": "PRRT_2", "isResolved": false, "path": "README.md",
									"line": nil, "originalLine": nil, "resolvedBy": nil,
									"comments": map[string]any{"pageInfo": map[string]any{"hasNextPage": false}, "nodes": []any{}},
								},
							},
						},
					},
				},
			},
		})
	}))
	defer srv.Close()

	got, err := newTestClient(t, srv).ListPullRequestReviewThreads(context.Background(), "owner", "repo", 42)
	require.NoError(t, err)
	assert.Equal(t, "owner", request["variables"].(map[string]any)["owner"])
	assert.Equal(t, "repo", request["variables"].(map[string]any)["name"])
	assert.Equal(t, float64(42), request["variables"].(map[string]any)["number"])
	assert.Len(t, got.Threads, 2)
	assert.Equal(t, forge.ReviewThread{
		ID: "PRRT_1", IsResolved: true, Path: "main.go", Line: &line,
		OriginalLine: &originalLine, ResolvedBy: "reviewer", ResolvedByType: "User",
		Comments: []forge.ReviewThreadComment{{
			Author: "reviewer", AuthorType: "User", Body: "please update this", CreatedAt: "2026-10-04T10:00:00Z",
		}}, CommentsTruncated: true,
	}, got.Threads[0])
	assert.Nil(t, got.Threads[1].Line)
	assert.Empty(t, got.Threads[1].ResolvedBy)
}

func TestListPullRequestReviewThreads_GHESGraphQLEndpoint(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		require.Equal(t, "/api/graphql", r.URL.Path)
		_, _ = w.Write([]byte(`{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":false,"endCursor":""},"nodes":[]}}}}}`))
	}))
	defer srv.Close()

	client := New("test-token").WithBaseURL(srv.URL + "/api/v3").WithAfterFunc(noWaitAfter)
	_, err := client.ListPullRequestReviewThreads(context.Background(), "owner", "repo", 1)
	require.NoError(t, err)
}

func TestListPullRequestReviewThreads_PaginatesAndCaps(t *testing.T) {
	var calls int
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls++
		var body struct {
			Variables struct {
				Cursor *string `json:"cursor"`
			} `json:"variables"`
		}
		require.NoError(t, json.NewDecoder(r.Body).Decode(&body))
		if calls == 1 {
			assert.Nil(t, body.Variables.Cursor)
		} else {
			require.NotNil(t, body.Variables.Cursor)
			assert.Equal(t, fmt.Sprintf("cursor-%d", calls-1), *body.Variables.Cursor)
		}
		json.NewEncoder(w).Encode(map[string]any{"data": map[string]any{"repository": map[string]any{
			"pullRequest": map[string]any{"reviewThreads": map[string]any{
				"pageInfo": map[string]any{"hasNextPage": true, "endCursor": fmt.Sprintf("cursor-%d", calls)},
				"nodes":    []any{map[string]any{"id": fmt.Sprintf("thread-%d", calls), "comments": map[string]any{"pageInfo": map[string]any{"hasNextPage": false}, "nodes": []any{}}}},
			}},
		}}})
	}))
	defer srv.Close()

	got, err := newTestClient(t, srv).ListPullRequestReviewThreads(context.Background(), "owner", "repo", 1)
	require.NoError(t, err)
	assert.Equal(t, 20, calls)
	assert.True(t, got.Truncated)
	assert.Len(t, got.Threads, 20)
}

func TestListPullRequestReviewThreads_Errors(t *testing.T) {
	tests := []struct {
		name    string
		status  int
		body    string
		wantErr string
	}{
		{name: "graphql error", status: http.StatusOK, body: `{"errors":[{"message":"forbidden"}]}`, wantErr: "forbidden"},
		{name: "invalid json", status: http.StatusOK, body: `{`, wantErr: "decode pull request review threads"},
		{name: "missing cursor", status: http.StatusOK, body: `{"data":{"repository":{"pullRequest":{"reviewThreads":{"pageInfo":{"hasNextPage":true,"endCursor":""},"nodes":[]}}}}}`, wantErr: "missing pagination cursor"},
		{name: "http error", status: http.StatusForbidden, body: `{"message":"denied"}`, wantErr: "page 1"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
				w.WriteHeader(tt.status)
				_, _ = w.Write([]byte(tt.body))
			}))
			defer srv.Close()

			_, err := newTestClient(t, srv).ListPullRequestReviewThreads(context.Background(), "o", "r", 1)
			require.Error(t, err)
			assert.Contains(t, err.Error(), tt.wantErr)
		})
	}
}
