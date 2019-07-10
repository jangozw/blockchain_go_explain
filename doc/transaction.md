# 比特币中的交易详解

UTXO 是 Unspent Transaction Output 的缩写，意指“为花费的交易输出”，是中本聪最早在比特币中采用的一种技术方案。因为比特币中没有账户的概念，也就没有保存用户余额数值的机制。因为区块链中的历史交易都是被保存且不可修改的，而每一个交易（如前所述的Transaction）中又保存了“谁转移了多少给谁”的信息，所以要计算用户账户余额，只需要遍历所有交易进行累计即可。

账户的余额其实是之前其他人转给该账户的钱处于锁定状态，要使用这笔钱就要解锁并且把发送人改为别人即可。 一笔交易是一系列的输入输出的集合，输入是寻找用户可花费的输出（utxo）, 输出是用户这笔交易要把金额给谁，包含输出给别人（转账）， 输出给自己（找零）,直接要代码定义的结构更直观。


## 基本概念
### 1， 输入
```go
type TXInput struct {
    Txid      []byte  
    Vout      int // 是utxo 的某个下标    
    Signature []byte
    PubKey    []byte
}
```
>>
输入TXInput:
* Txid : 交易ID（这个输入使用的是哪个交易的输出）
* Vout : 该输入单元指向本次交易输出数组的下标，通俗讲就是，这个输入使用的是Txid中的第几个输出。
* Signature : 输入发起方（转账出去方）的私钥签名本Transaction，表示自己认证了这个输入TXInput。
* PubKey : 输入发起方的公钥

### 2， 输出
```go
type TXOutput struct {
    Value      int //金额
    PubKeyHash []byte
}
```
>>
输出TXOutput：
* Value : 表示这个输出中的代币数量
* PubKeyHash : 存放了一个用户的公钥的hash值，表示这个输出里面的Value是属于哪个用户的


### 3， 一个交易（多个输入输出的集合）
```go
type Transaction struct {
    ID   []byte        //交易唯一ID
    Vin  []TXInput     //交易输入序列
    Vout []TXOutput    //交易输出序列
}
```

# 交易范例

Alice 去咖啡店买一杯咖啡，她需要支付给老板Bob的咖啡金额是5 个比特币。接下来看代码如何实现：

## 1，在区块链中查询Alice的未花费的输出
如果一个账户需要进行一次交易，把自己的代币转给别人，由于没有一个账号系统可以直接查询余额和变更，而在utxo模型里面一个用户账户余额就是这个用户的所有utxo（未花费的输出）记录的合集，因此需要查询用户的转账额度是否足够，以及本次转账需要消耗哪些output（将“未花费”的output变成”已花费“的output），通过遍历区块链中每个区块中的每个交易中的output来得到结果。
下面看看怎么查找一个特定用户的utxo，utxo_set.go相关代码如下：
```go

// 找到用户可花费的输出，满足花费的金额即可，返回的可花费的金额 和 对应的交易输出的下标
// 注意返回的可花费的金额accumulated 是 大于等于 要花费的金额的，因为可花费金额是该用户的多笔不同金额的utxo累加的
// 如果返回的utxo金额累计大于要花费的金额，则多出的部分就是找零，相当于多个utxo是面额不同的金额累加成一个大额
//注意： 返回的第二个参数是某笔交易的某个下标 如 trans[txid_1111]=1 就是txid_1111这个交易的下标为1的输出被选用了
// FindSpendableOutputs finds and returns unspent outputs to reference in inputs
func (u UTXOSet) FindSpendableOutputs(pubkeyHash []byte, amount int) (int, map[string][]int) {
	unspentOutputs := make(map[string][]int)
	accumulated := 0
	db := u.Blockchain.db

	err := db.View(func(tx *bolt.Tx) error {
		b := tx.Bucket([]byte(utxoBucket))
		c := b.Cursor()

		for k, v := c.First(); k != nil; k, v = c.Next() {
			txID := hex.EncodeToString(k)
			outs := DeserializeOutputs(v)

			for outIdx, out := range outs.Outputs {
				if out.IsLockedWithKey(pubkeyHash) && accumulated < amount {
					accumulated += out.Value
					unspentOutputs[txID] = append(unspentOutputs[txID], outIdx)
				}
			}
		}

		return nil
	})
	if err != nil {
		log.Panic(err)
	}

	return accumulated, unspentOutputs
}
```
FindSpendableOutputs查找区块链上pubkeyHash账户的utxo集合，直到这些集合的累计未花费金额达到需求的amount为止。

blockchain_go中使用嵌入式key-value数据库boltdb存储区块链和未花费输出等信息，其中utxoBucket是所有用户未花费输出的bucket，其中的key表示交易ID，value是这个交易中未被引用的所有output的集合。所以通过遍历查询本次交易需要花费的output，得到Transaction的txID和这个output在Transaction中的输出数组中的下标组合unspentOutputs。

另外一个重点是utxobucket中保存的未花费输出结合是关于所有账户的，要查询特定账户需要对账户进行判断，因为TXOutput中有pubkeyhash字段，用来表示该输出属于哪个用户，此处采用out.IsLockedWithKey(pubkeyHash)判断特定output是否是属于给定用户。

## 2, 构建一个交易
需要发起一笔交易的时候，需要新建一个Transaction，通过交易发起人的钱包得到足够的未花费输出，构建出交易的输入和输出，完成签名即可，blockchain_go中的实现如下

函数参数：
- wallet : 用户钱包参数，存储用户的公私钥，用于交易的签名和验证。
- to : 交易转账的目的地址（转账给谁）。
- amount : 需要交易的代币额度。
- UTXOSet : uxto集合，查询用户的未花费输出。
```go
func NewUTXOTransaction(wallet *Wallet, to string, amount int, UTXOSet *UTXOSet) *Transaction {
	var inputs []TXInput
	var outputs []TXOutput

	pubKeyHash := HashPubKey(wallet.PublicKey)
	// 查询用户可花费金额 和 对应的可花费交易的下标
	acc, validOutputs := UTXOSet.FindSpendableOutputs(pubKeyHash, amount)
	//可花费金额小于 要输出的金额 则报错
	if acc < amount {
		log.Panic("ERROR: Not enough funds")
	}

	// Build a list of inputs
	for txid, outs := range validOutputs {
		txID, err := hex.DecodeString(txid)
		if err != nil {
			log.Panic(err)
		}

		for _, out := range outs {
			input := TXInput{txID, out, nil, wallet.PublicKey}
			inputs = append(inputs, input)
		}
	}

	// Build a list of outputs
	from := fmt.Sprintf("%s", wallet.GetAddress())
	outputs = append(outputs, *NewTXOutput(amount, to))
	// 如果返回的utxo金额累计大于要花费的金额，则多出的部分就是找零，相当于多个utxo是面额不同的金额累加成一个大额
	if acc > amount {
		outputs = append(outputs, *NewTXOutput(acc-amount, from)) // a change 零钱
	}

	tx := Transaction{nil, inputs, outputs}
	tx.ID = tx.Hash()
	UTXOSet.Blockchain.SignTransaction(&tx, wallet.PrivateKey)

	return &tx
}
```
因为用户的总金额是通过若干未花费输出累计起来的，而每个output所携带金额不一而足，所以每次转账可能需要消耗多个不同的output，而且还可能涉及找零问题。以上查询返回了一批未花费输出列表validOutputs和他们总共的金额acc. 找出来的未花费输出列表就是本次交易的输入，并将输出结果构造output指向目的用户，并检查是否有找零，将找零返还。

如果交易顺利完成，转账发起人的“未花费输出”被消耗掉变成了花费状态，而转账接收人to得到了一笔新的“未花费输出”，之后他自己需要转账时，查询自己的未花费输出，即可使用这笔钱。

最后需要对交易进行签名，表示交易确实是由发起人本人发起（私钥签名），而不是被第三人冒充。

# 交易的签名和验证
####  签名
交易的有效性需要首先建立在发起人签名的基础上，防止他人冒充转账或者发起人抵赖，blockchain_go中交易签名实现如下：
```go
// SignTransaction signs inputs of a Transaction
func (bc *Blockchain) SignTransaction(tx *Transaction, privKey ecdsa.PrivateKey) {
    prevTXs := make(map[string]Transaction)

    for _, vin := range tx.Vin {
        prevTX, err := bc.FindTransaction(vin.Txid)
        if err != nil {
            log.Panic(err)
        }
        prevTXs[hex.EncodeToString(prevTX.ID)] = prevTX
    }

    tx.Sign(privKey, prevTXs)
}

// Sign signs each input of a Transaction
func (tx *Transaction) Sign(privKey ecdsa.PrivateKey, prevTXs map[string]Transaction) {
    if tx.IsCoinbase() {
        return
    }

    for _, vin := range tx.Vin {
        if prevTXs[hex.EncodeToString(vin.Txid)].ID == nil {
            log.Panic("ERROR: Previous transaction is not correct")
        }
    }

    txCopy := tx.TrimmedCopy()

    for inID, vin := range txCopy.Vin {
        prevTx := prevTXs[hex.EncodeToString(vin.Txid)]
        txCopy.Vin[inID].Signature = nil
        // 注意vin.Vout 是该账户之前存在的某比交易的某个可花费输出的下标
        txCopy.Vin[inID].PubKey = prevTx.Vout[vin.Vout].PubKeyHash

        dataToSign := fmt.Sprintf("%x\n", txCopy)

        r, s, err := ecdsa.Sign(rand.Reader, &privKey, []byte(dataToSign))
        if err != nil {
            log.Panic(err)
        }
        signature := append(r.Bytes(), s.Bytes()...)

        tx.Vin[inID].Signature = signature
        txCopy.Vin[inID].PubKey = nil
    }
}
```


交易输入的签名信息是放在TXInput中的signature字段，其中需要包括用户的pubkey，用于之后的验证。需要对每一个输入做签名。

####  验证
交易签名是发生在交易产生时，交易完成后，Transaction会把交易广播给邻居。节点在进行挖矿时，会整理一段时间的所有交易信息，将这些信息打包进入新的区块，成功加入区块链以后，这个交易就得到了最终的确认。但是在挖矿节点打包交易前，需要对交易的有效性做验证，以防虚假数据，验证实现如下：
```go
// MineBlock mines a new block with the provided transactions
func (bc *Blockchain) MineBlock(transactions []*Transaction) *Block {
    var lastHash []byte
    var lastHeight int

    for _, tx := range transactions {
        // TODO: ignore transaction if it's not valid
        if bc.VerifyTransaction(tx) != true {
            log.Panic("ERROR: Invalid transaction")
        }
    }


    return block
}
// VerifyTransaction verifies transaction input signatures
func (bc *Blockchain) VerifyTransaction(tx *Transaction) bool {
    if tx.IsCoinbase() {
        return true
    }

    prevTXs := make(map[string]Transaction)

    for _, vin := range tx.Vin {
        prevTX, err := bc.FindTransaction(vin.Txid)
        if err != nil {
            log.Panic(err)
        }
        prevTXs[hex.EncodeToString(prevTX.ID)] = prevTX
    }

    return tx.Verify(prevTXs)
}
// Verify verifies signatures of Transaction inputs
func (tx *Transaction) Verify(prevTXs map[string]Transaction) bool {
    if tx.IsCoinbase() {
        return true
    }

    for _, vin := range tx.Vin {
        if prevTXs[hex.EncodeToString(vin.Txid)].ID == nil {
            log.Panic("ERROR: Previous transaction is not correct")
        }
    }

    txCopy := tx.TrimmedCopy()
    curve := elliptic.P256()

    for inID, vin := range tx.Vin {
        prevTx := prevTXs[hex.EncodeToString(vin.Txid)]
        txCopy.Vin[inID].Signature = nil
        txCopy.Vin[inID].PubKey = prevTx.Vout[vin.Vout].PubKeyHash

        r := big.Int{}
        s := big.Int{}
        sigLen := len(vin.Signature)
        r.SetBytes(vin.Signature[:(sigLen / 2)])
        s.SetBytes(vin.Signature[(sigLen / 2):])

        x := big.Int{}
        y := big.Int{}
        keyLen := len(vin.PubKey)
        x.SetBytes(vin.PubKey[:(keyLen / 2)])
        y.SetBytes(vin.PubKey[(keyLen / 2):])

        dataToVerify := fmt.Sprintf("%x\n", txCopy)

        rawPubKey := ecdsa.PublicKey{Curve: curve, X: &x, Y: &y}
        if ecdsa.Verify(&rawPubKey, []byte(dataToVerify), &r, &s) == false {
            return false
        }
        txCopy.Vin[inID].PubKey = nil
    }

    return true
}
```


可以看到验证的时候也是每个交易的每个TXInput都单独进行验证，和签名过程很相似，需要构造相同的交易数据txCopy，验证时会用到签名设置的TxInput.PubKeyHash生成一个原始的PublicKey，将前面的signature分拆后通过ecdsa.Verify进行验证。

# 总结
以上简单分析和整理了blockchain_go中的交易和UTXO机制的实现过程，加深了区块链中的挖矿，交易和转账的基础技术原理的理解。