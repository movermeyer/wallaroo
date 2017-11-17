package application

import (
	wa "wallarooapi"
	"wallarooapi/application/repr"
)

func MakeKafkaHostPort(host string, port uint64) *KafkaHostPort {
	return &KafkaHostPort{host, port}
}

type KafkaHostPort struct {
	host string
	port uint64
}

func (khp *KafkaHostPort) Repr() *repr.KafkaHostPort {
	return &repr.KafkaHostPort{khp.host, khp.port}
}

func MakeKafkaSourceConfig(topic string, brokers []*KafkaHostPort, logLevel string, decoder wa.Decoder) *KafkaSourceConfig {
	return &KafkaSourceConfig{topic, brokers, logLevel, decoder, 0}
}

type KafkaSourceConfig struct {
	topic string
	brokers []*KafkaHostPort
	logLevel string
	decoder wa.Decoder
	decoderId uint64
}

func (ksc *KafkaSourceConfig) brokersRepr() []*repr.KafkaHostPort {
	brokers := make([]*repr.KafkaHostPort, 0)
	for _, b := range ksc.brokers {
		brokers = append(brokers, b.Repr())
	}
	return brokers
}

func (ksc *KafkaSourceConfig) SourceConfigRepr() interface{} {
	return repr.MakeKafkaSourceConfig(ksc.topic, ksc.brokersRepr(), ksc.logLevel, ksc.decoderId)
}

func (ksc *KafkaSourceConfig) AddDecoder() uint64 {
	ksc.decoderId = wa.AddComponent(ksc.decoder)
	return ksc.decoderId
}
