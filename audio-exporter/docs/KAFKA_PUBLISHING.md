# Kafka Event Publishing Not Enabled

Kafka event publishing is not enabled for this service. To enable it:

1. Regenerate project with `cargo generate`:
   - Select "yes" when prompted for Kafka event publishing
   - Provide broker URL, topic name, and event name

2. Or add manually:
   - Include "kafka" in the `features` array in `cargo-generate.toml`
   - Provide broker URL, topic, and event name when prompted
   - Update configuration templates with Kafka settings

See [KAFKA_EVENTING.md](./KAFKA_EVENTING.md) for event source (Knative Eventing) documentation.

