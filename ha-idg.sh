#!/bin/bash

DIR=$(cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd)
source ${DIR}/../_common/common.sh

set -e

cluster=ha

api_domains=(apic-ha     apic-lts)
v5c_domains=(apic-ha-v5c apic-lts-v5c)
domains=(${api_domains[@]} ${v5c_domains[@]})

servers=("lts-idg1.apicww.cloud" "lts-idg2.apicww.cloud" "lts-idg3.apicww.cloud")
server_auth="--basic --user $(cat ha-idg-creds)"

command_set=$(cat ha-idg-commandset.json)

csr_subject="/C=US/ST=Minnesota/L=Saint Paul/O=IBM/OU=IBM Cloud/CN=API Connect"

skip_domains=false
skip_keygen=false
skip_profiles=false
skip_extra_services=false

function doAction {

	local idg=$1
	local domain=$2
	local action=$3
	shift ; shift ; shift

	local command=$(jq -ce '.'$action <<< $command_set)

	# parameter substitution
	IFS=$'\n'
	for p in $(jq -cer '.parameters|.[]' <<< $command); do
		[ -z "$1" ] && break
		command=$(echo ${command//"$p"/$1})
		shift
	done
	unset IFS

	local verb=''; verb="$(jq -cer .verb <<< $command)" || verb='GET'
	local t='' ; t="$(jq -cer .type <<< $command)" || t='config'
	local c='' ; c="/$(jq -cer .class <<< $command)" || c=''
	local n='' ; n="/$(jq -cer .name <<< $command)" || n=''

	local curlUrl="https://${idg}:5554/mgmt/${t}/${domain}${c}${n}"
	local curlCmd="curl -X $verb ${server_auth} -s ${curlUrl}"

	comment "$verb $curlUrl"

	payload=$(jq -ce .payload <<< $command)
	if [ $? == 0 ]; then
		doActionResult=$($curlCmd -T - <<< $payload | jq -c .)
	else 
		payload=''
		doActionResult=$($curlCmd | jq -c .)
	fi

	# terminate on error
	if jq -e .error <<< $doActionResult > /dev/null ; then
		error "Error on action $action"
		[ -z $payload ] || jq . <<< $payload
		echo "Result:"
		jq . <<< $doActionResult
		false
	fi
}

for domain in ${domains[@]}; do

	h1 Building keys on domain ${domain}

	for idg in ${servers[@]}; do
		if ! $skip_domains; then
			doAction $idg default domain $domain
			doAction $idg default save
		fi
	done

	if $skip_keygen; then
		comment "Skipping"
	else

		for certPair in ssl-${domain}-client ssl-${domain}-server ssl-${domain}-peering; do

			h2 "Generating ${certPair} keys"

			for idg in ${servers[@]}; do
				doAction $idg $domain keygen ${certPair}
				if ! $(jq -e '.Keygen' <<< $keygenResult >/dev/null); then
					echo $doAction
					jq . <<< $doAction
					false
				fi
			done

			h2 "Building idCreds"

			for idg in ${servers[@]}; do

				doAction $idg $domain crt ${certPair}
				doAction $idg $domain key ${certPair}
				doAction $idg $domain idcred ${certPair}

			done

		done
	fi

	h2 "Building SSL Profiles"

	if $skip_profiles; then
		comment "Skipping"
	else
		for idg in ${servers[@]}; do

			doAction $idg $domain sslclient ssl-${domain}-client
			doAction $idg $domain sslserver ssl-${domain}-server
			doAction $idg $domain sslclient ssl-${domain}-peering
			doAction $idg $domain sslserver ssl-${domain}-peering

		done
	fi

done

h2 "Configuration Sequences (API Gateways Only)"

if $skip_extra_services; then
	comment "Skipping"
else
	for domain in ${api_domains[@]}; do
		for idg in ${servers[@]}; do
			doAction $idg $domain configseq
		done
	done
fi

h2 "Statistics Services (v5c Gateways Only)"

if $skip_extra_services; then
	comment "Skipping"
else
	for domain in ${v5c_domains[@]}; do
		for idg in ${servers[@]}; do
			doAction $idg $domain statistics
		done
	done
fi

# h2 "API Connect Gateway Service"

# TODO ?


h2 "Saving everything"

for domain in ${domains[@]}; do
	for idg in ${servers[@]}; do
		doAction $idg $domain save
	done
done

end 0 'IDG SSL SETUP COMPLETE'





