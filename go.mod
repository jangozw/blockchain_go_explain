module github.com/Jeiwan/blockchain_go

go 1.12

require github.com/boltdb/bolt v1.3.1

replace (
	golang.org/x/crypto v0.0.0-20190701094942-4def268fd1a4 => github.com/golang/crypto v0.0.0-20180820150726-614d502a4dac
	golang.org/x/net v0.0.0-20180821023952-922f4815f713 => github.com/golang/net v0.0.0-20180826012351-8a410e7b638d
)
