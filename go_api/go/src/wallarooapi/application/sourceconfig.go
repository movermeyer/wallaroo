package application

type SourceConfig interface {
	SourceConfigRepr() interface{}
	AddDecoder() uint64
}
