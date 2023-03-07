package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"io/ioutil"
	"log"
	"net/http"
	"os"
	"strings"
	"time"

	"cloud.google.com/go/datastore"
	"cloud.google.com/go/pubsub"
)

var projectID string
var topicID string

type visit struct {
	Timestamp time.Time
	UserIP    string
	UserEmail string
}

func main() {
	projectID = os.Getenv("GOOGLE_PROJECT")
	topicID = os.Getenv("TOPIC")
	port := os.Getenv("PORT")
	if port == "" {
		port = "8080"
		log.Printf("Defaulting to port %s", port)
	}

	http.HandleFunc("/submit", SubmitHandler)
	http.HandleFunc("/push", PushHandler)

	log.Printf("Listening on port %s", port)
	if err := http.ListenAndServe(":"+port, nil); err != nil {
		log.Fatal(err)
	}
}

type PubSubMessage struct {
	Message struct {
		Data []byte `json:"data,omitempty"`
		ID   string `json:"id"`
	} `json:"message"`
	Subscription string `json:"subscription"`
}

func extractEmail(reqToken string) (string, error) {
	splitToken := strings.Split(reqToken, "bearer ")
	reqToken = splitToken[1]
	parts := strings.Split(reqToken, ".")
	tok, err := base64.RawURLEncoding.DecodeString(parts[1])
	var m map[string]interface{}
	err = json.Unmarshal(tok, &m)
	return m["email"].(string), err
}

func SubmitHandler(w http.ResponseWriter, r *http.Request) {
	ctx := context.Background()
	client, err := pubsub.NewClient(ctx, projectID)
	if err != nil {
		log.Fatalf("pubsub.NewClient: %s", err)
	}
	defer client.Close()
	t := client.Topic(topicID)

	reqToken := r.Header.Get("Authorization")
	email, err := extractEmail(reqToken)
	if err != nil {
		log.Fatalf("Failed to get email: %s", err)
	}

	ip := r.Header.Get("X-Forwarded-For")
	log.Printf("Get query from %s", ip)

	v := &visit{
		UserEmail: email,
		Timestamp: time.Now(),
		UserIP:    ip,
	}

	data, _ := json.Marshal(v)
	result := t.Publish(ctx, &pubsub.Message{
		Data: []byte(data),
	})

	id, err := result.Get(ctx)
	if err != nil {
		log.Fatalf("Failed to publish: %s", err)
	}
	log.Printf("Published message; msg ID: %v\n", id)
}

func PushHandler(w http.ResponseWriter, r *http.Request) {
	ctx := context.Background()
	datastoreClient, err := datastore.NewClient(ctx, projectID)
	if err != nil {
		log.Fatal(err)
	}
	defer datastoreClient.Close()

	var m PubSubMessage
	body, err := ioutil.ReadAll(r.Body)
	if err != nil {
		log.Fatalf("ioutil.ReadAll: %v", err)
	}
	if err := json.Unmarshal(body, &m); err != nil {
		log.Fatalf("json.Unmarshal: %v", err)
	}

	var v visit
	if err := json.Unmarshal(m.Message.Data, &v); err != nil {
		log.Fatal(err)
	}
	log.Printf("Received %+v", v)

	visitKey := datastore.NameKey("vpcsc-demo", v.UserEmail, nil)
	if _, err := datastoreClient.Put(ctx, visitKey, &v); err != nil {
		log.Fatalf("Failed to save task: %v", err)
	}
	log.Printf("Saved %+v !", v)
}
