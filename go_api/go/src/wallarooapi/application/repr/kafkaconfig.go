package repr

func MakeKafkaHostPort(host string, port uint64) *KafkaHostPort {
	return &KafkaHostPort{host, port}
}

type KafkaHostPort struct {
	Host string
	Port uint64
}

func MakeKafkaSourceConfig(topic string, brokers []*KafkaHostPort, logLevel string, decoderId uint64) *KafkaSourceConfig {
	return &KafkaSourceConfig{"KafkaSourceConfig", topic, brokers, logLevel, decoderId}
}

type KafkaSourceConfig struct {
	Class string
	Topic string
	Brokers []*KafkaHostPort
	LogLevel string
	DecoderId uint64
}
