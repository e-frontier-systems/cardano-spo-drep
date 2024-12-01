#!/bin/bash

spo_drep() {

    COMMAND=""
    SELECTED=""

    while true
    do
        echo "1. DRepへ委任"
        echo "2. 常に棄権"
        echo "3. 常に不信任"
        echo "-------------"
        echo "4. キャンセル"

        read -r -n 1 -p "> " DELEG

        case $DELEG in
            1 )
                echo "DRepIDを入力してください"
                read -r -p "> " DRepID
                DRep=$(get_drep_info "$DRepID")
                if ! check_active_drep "$DRep"; then
                    echo "DRepの情報に問題が見つかりました。"
                    continue
                fi
                DRepHex=$(echo "$DRep" | jq .[0].hex)
                COMMAND="--drep-key-hash ${DRepHex:1:-1}"
                SELECTED="DRepID: '${DRepID}' に委任する"
                break
                ;;
            2 )
                COMMAND="--always-abstain"
                SELECTED="常に棄権する"
                break
                ;;
            3 )
                COMMAND="--always-no-confidence"
                SELECTED="常に不信任投票する"
                break
                ;;
            4 )
                exit 0
                ;;
            * )
                continue
                ;;
        esac

    done

    while true
    do
        echo "以下の内容でよろしいですか？"
        echo
        echo "${SELECTED}"
        echo
        read -r -n 1 -p "[1] は い   [2] キャンセル" CONFIRM

        case $CONFIRM in
            1 )
                break
                ;;
            2 )
                exit 0
                ;;
        esac
    done

    cd $NODE_HOME

    while true
    do
        clear

        echo "エアギャップにて以下のコマンドを実行してください。"
        echo
        echo "cd \$NODE_HOME"
        echo "cardano-cli conway stake-address vote-delegation-certificate \\
    --stake-verification-key-file stake.vkey \\
    $COMMAND \\
    --out-file vote-deleg.cert"

        echo
        echo
        echo "コマンドを実行したら、BPの \$NODE_HOME ディレクトリへ vote-deleg.cert をコピーしてください。"
        echo
        echo
        read -r -p "上記作業が終わったらEnterキーを押して次へ進みます >"


        if [ -f "vote-deleg.cert" ]; then
            break
        fi
        read -r -p "vote-deleg.certファイルが見つかりません。"
    done

    clear
    echo "トランザクションファイルを作成しています..."
    echo

    currentSlot=$(cardano-cli conway query tip $NODE_NETWORK | jq -r '.slot')

    cardano-cli conway query utxo \
        --address $(cat payment.addr) \
        $NODE_NETWORK > fullUtxo.out

    tail -n +3 fullUtxo.out | sort -k3 -nr > balance.out


    tx_in=""
    total_balance=0
    while read -r utxo; do
        type=$(awk '{ print $6 }' <<< "${utxo}")
        if [[ ${type} == 'TxOutDatumNone' ]]
        then
            in_addr=$(awk '{ print $1 }' <<< "${utxo}")
            idx=$(awk '{ print $2 }' <<< "${utxo}")
            utxo_balance=$(awk '{ print $3 }' <<< "${utxo}")
            total_balance=$((${total_balance}+${utxo_balance}))
            echo TxHash: ${in_addr}#${idx}
            echo ADA: ${utxo_balance}
            tx_in="${tx_in} --tx-in ${in_addr}#${idx}"
        fi
    done < balance.out
    txcnt=$(cat balance.out | wc -l)

    cardano-cli conway transaction build-raw \
        ${tx_in} \
        --tx-out $(cat payment.addr)+${total_balance} \
        --invalid-hereafter $(( ${currentSlot} + 10000 )) \
        --fee 200000 \
        --out-file tx.tmp \
        --certificate vote-deleg.cert

    fee=$(cardano-cli conway transaction calculate-min-fee \
        --tx-body-file tx.tmp \
        --tx-in-count ${txcnt} \
        --tx-out-count 1 \
        $NODE_NETWORK \
        --witness-count 2 \
        --byron-witness-count 0 \
        --protocol-params-file params.json | awk '{ print $1 }')

    txOut=$((${total_balance}-${fee}))

    cardano-cli conway transaction build-raw \
        ${tx_in} \
        --tx-out $(cat payment.addr)+${txOut} \
        --invalid-hereafter $(( ${currentSlot} + 10000 )) \
        --fee ${fee} \
        --certificate-file vote-deleg.cert \
        --out-file tx.raw

    clear
    echo "トランザクション手数料: ${fee}"
    echo
    echo "BPの\$NODE_HOMEディレクトリ内の tx.raw ファイルをエアギャップの\$NODE_HOMEディレクトリへコピーし、"
    echo "以下のコマンドを実行してください。"
    echo
    echo "cd \$NODE_HOME"
    echo "cardano-cli conway transaction sign \\
    --tx-body-file tx.raw \\
    --signing-key-file payment.skey \\
    --signing-key-file stake.skey \\
    \$NODE_NETWORK \\
    --out-file tx.signed"
    echo
    echo
    echo "コマンドを実行後、tx.signedファイルをエアギャップからBPの\$NODE_HOMEディレクトリにコピーします。"
    echo

    read -r -p "上記作業が終わったらEnterキーを押して次へ進みます >"

    clear
    while true
    do
        echo "トランザクションを送信します。よろしいですか？"
        read -r -n 1 -p "[1] 送信する   [2] キャンセル" SEND
        echo
        case $SEND in
            1 )
                break
                ;;
            2 )
                echo "キャンセルしました"
                exit 0
                ;;
            * )
                continue
                ;;
        esac
    done

    tx_id=$(cardano-cli conway transaction txid --tx-body-file tx.signed)
    tx_result=$(cardano-cli conway transaction submit --tx-file tx.signed $NODE_NETWORK)
    echo
    echo '----------------------------------------'
    echo 'Tx送信結果'
    echo '----------------------------------------'
    echo $tx_result
    echo
    if [[ $tx_result == "Transaction"* ]]; then
        echo "トランザクションURL"
        echo "https://cardanoscan.io/transaction/$tx_id"
        echo
        echo "Tx送信に成功しました"
    else
        echo "Tx送信に失敗しました"
    fi

    return 1;
}


get_drep_info() {
    curl -sS -X POST "https://api.koios.rest/api/v1/drep_info" \
        -H "accept: application/json" \
        -H "content-type: application/json" \
        -d "{\"_drep_ids\":[\"$1\"]}"
}


check_active_drep() {

    length=$(echo "$1" | jq length)
    if [ "$length" -ne 1 ]; then
        echo "DRepの情報が見つかりませんでした..."
        return 1
    fi
    active=$(echo "$1" | jq .[0].active)
    if [ "$active" != "true" ]; then
        echo "指定されたDRepは有効ではありません..."
        return 1
    fi

    return 0
}


spo_drep
