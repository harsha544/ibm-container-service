#!/bin/bash

#
# deploy_charts.sh: Deploys the Helm Charts required to create an IBM Blockchain Platform
#                   development sandbox using IBM Container Service.
#
# Contributors:     Eddie Allen
#                   Mihir Shah
#                   Dhyey Shah
#
# Version:          7 December 2017
#

NOP=$1

if [ -z "$NOP" ]
then
	NOP=2
fi

echo "$NOP"

#
# checkDependencies: Checks to ensure required tools are installed.
#
function checkDependencies() {
    type kubectl >/dev/null 2>&1 || { echo >&2 "I require kubectl but it is not installed.  Aborting."; exit 1; }
    type helm >/dev/null 2>&1 || { echo >&2 "I require helm but it is not installed.  Aborting."; exit 1; }
}

#
# colorEcho:  Prints the user specified string to the screen using the specified color.
#             If no color is provided, the default no color option is used.
#
# Parameters: ${1} - The string to print.
#             ${2} - The color to use for printing the string.
#
#             NOTE: The following color options are available:
#
#                   [0|1]30, [dark|light] black
#                   [0|1]31, [dark|light] red
#                   [0|1]32, [dark|light] green
#                   [0|1]33, [dark|light] brown
#                   [0|1]34, [dark|light] blue
#                   [0|1]35, [dark|light] purple
#                   [0|1]36, [dark|light] cyan
#
function colorEcho() {
    # Check for proper usage
    if [[ ${#} == 0 || ${#} > 2 ]]; then
        echo "usage: ${FUNCNAME} <string> [<0|1>3<0-6>]"
        return -1
    fi

    # Set default color to white
    MSSG=${1}
    CLRCODE=${2}
    LIGHTDARK=1
    MSGCOLOR=0

    # If color code was provided, then set it
    if [[ ${#} == 2 ]]; then
        LIGHTDARK=${CLRCODE:0:1}
        MSGCOLOR=${CLRCODE:1}
    fi

    # Print out the message
    echo -e -n "${MSSG}" | awk '{print "\033['${LIGHTDARK}';'${MSGCOLOR}'m" $0 "\033[1;0m"}'
}

#
# cleanEnvironment: Cleans the services, volumes, and pods from the Kubernetes cluster.
#
function cleanEnvironment() {
    HELM_RELEASES=$(helm list | tail -n +2 | awk '{ print $1 }')

    # Delete any existing releases
    if [[ ! -z ${HELM_RELEASES// /} ]]; then
        echo -n "Deleting the following helm releases: "
        echo ${HELM_RELEASES}...
        helm delete --purge ${HELM_RELEASES}
        sleep 2
    fi

    # Wipe the /shared persistent volume if it exists (it should be removed with chart removal)
    kubectl get pv shared > /dev/null 2>&1
    if [[ ${?} -eq 0 ]]; then
        kubectl create -f ../cs-offerings/kube-configs/wipe_shared.yaml

        # Wait for the wipe shared pod to finish
        while [ "$(kubectl get pod -a wipeshared | grep wipeshared | awk '{print $3}')" != "Completed" ]; do
            echo "Waiting for the shared folder to be erased..."
            sleep 1;
        done

        # Delete the wipe shared pod
        kubectl delete -f ../cs-offerings/kube-configs/wipe_shared.yaml
    fi
}

#
# getPods: Updates the pod status variables.
#
function getPodStatus() {
    PODS=$(kubectl get pods -a)
    PODS_RUNNING=$(echo "${PODS}" | grep Running | wc -l)
    PODS_COMPLETED=$(echo "${PODS}" | grep Completed | wc -l)
    PODS_ERROR=$(echo "${PODS}" | grep Error | wc -l)
}

#
# checkPodStatus: Checks the status of all pods ensure the correct number are running,
#                 completed, and that none completed with errors.
#
# Parameters:     $1 - The expected number of pods in the 'Running' state.
#                 $2 - The expected number of pods in the 'Completed' state.
#
function checkPodStatus() {
    # Ensure arguments were passed
    if [[ ${#} -ne 2 ]]; then
        echo "Usage: ${FUNCNAME} <num_running_pods> <num_completed_pods>"
        return -1
    fi

    NUM_RUNNING=${1}
    NUM_COMPLETED=${2}

    # Get the status of the pods
    getPodStatus

    # Wait for the pods to initialize
    while [ "${PODS_RUNNING}" -ne ${NUM_RUNNING} ] || [ "${PODS_COMPLETED}" -ne ${NUM_COMPLETED} ]; do
        if [ "${PODS_ERROR}" -gt 0 ]; then
            colorEcho "\n$(basename $0): error: the following pods failed with errors:" 131
            colorEcho "$(echo "$PODS" | grep Error)" 131

            # Show the logs for failed pods
            for i in $(echo "$PODS" | grep Error | awk '{print $1}'); do
                # colorEcho "\n$ kubectl describe pod ${i}" 132
                # kubectl describe pod "${i}"

                if [[ ${i} =~ .*channel-create.* ]]; then
                    colorEcho "\n$ kubectl logs ${i} createchanneltx" 132
                    kubectl logs "${i}" "createchanneltx"

                    colorEcho "\n$ kubectl logs ${i} createchannel" 132
                    kubectl logs "${i}" "createchannel"
                else
                    colorEcho "\n$ kubectl logs ${i}" 132
                    kubectl logs "${i}"
                fi
            done

            exit -1
        fi

        colorEcho "Waiting for the pods to initialize..." 134
        sleep 2

        getPodStatus
    done

    colorEcho "Pods initialized successfully!\n" 134
}

#
# generateNetwork: Generates crypto-material based on number of peer.
#
function generateNetwork() {

##########################################################
# Updating crypto-config.yaml File
##########################################################

pushd ../sampleconfig >/dev/null 2>&1

echo "# ---------------------------------------------------------------------------
# "OrdererOrgs" - Definition of organizations managing orderer nodes
# ---------------------------------------------------------------------------
OrdererOrgs:
  # ---------------------------------------------------------------------------
  # Orderer
  # ---------------------------------------------------------------------------
  - Name: Orderer
    Domain: example.com
    # ---------------------------------------------------------------------------
    # "Specs" - See PeerOrgs below for complete description
    # ---------------------------------------------------------------------------
    Specs:
      - Hostname: orderer
# ---------------------------------------------------------------------------
# "PeerOrgs" - Definition of organizations managing peer nodes
# ---------------------------------------------------------------------------
PeerOrgs:" >> crypto-config.yaml
  for ((i=1; i<=$NOP; i++))
  do
	echo "  # ---------------------------------------------------------------------------" >> crypto-config.yaml
	echo "  # Org$i: See "Org$i" for full specification" >> crypto-config.yaml
	echo "  # ---------------------------------------------------------------------------" >> crypto-config.yaml	
	echo "  - Name: Org$i" >> crypto-config.yaml
	echo "    Domain: org$i.example.com" >> crypto-config.yaml
	echo "    Template:" >> crypto-config.yaml
	echo "      Count: 2" >> crypto-config.yaml
	echo "    Users:" >> crypto-config.yaml
	echo "      Count: 1"   >> crypto-config.yaml
  done 



##########################################################
# Updating configtx.yaml File
##########################################################



echo "---
################################################################################
#
#   Profile
#
#   - Different configuration profiles may be encoded here to be specified
#   as parameters to the configtxgen tool
#
################################################################################
Profiles:

    OrgsOrdererGenesis:
        Orderer:
            <<: *OrdererDefaults
            Organizations:
                - *OrdererOrg
        Consortiums:
            SampleConsortium:" >> configtx.yaml

# Updating Profiles Section
for ((i=1; i<=$NOP; i++))
do
	echo "                    - *Org$i" >> configtx.yaml
done

# Continue Updating Profiles Section

echo "    OrgsChannel:" >> configtx.yaml
echo "        Consortium: SampleConsortium" >> configtx.yaml
echo "        Application:" >> configtx.yaml
echo "            <<: *ApplicationDefaults" >> configtx.yaml
echo "            Organizations:" >> configtx.yaml

for ((i=1; i<=$NOP; i++))
do
        echo "                    - *Org$i" >> configtx.yaml
done

##########################################################
# Updating Organizations Section
##########################################################

echo "################################################################################" >> configtx.yaml
echo "#" >> configtx.yaml
echo "#   Section: Organizations" >> configtx.yaml
echo "#" >> configtx.yaml
echo "#   - This section defines the different organizational identities which will" >> configtx.yaml
echo "#   be referenced later in the configuration." >> configtx.yaml
echo "#" >> configtx.yaml
echo "################################################################################" >> configtx.yaml

echo "Organizations:" >> configtx.yaml
echo "    - &OrdererOrg" >> configtx.yaml
echo "        Name: OrdererOrg" >> configtx.yaml
echo "        ID: OrdererMSP" >> configtx.yaml
echo "        MSPDir: crypto-config/ordererOrganizations/example.com/msp" >> configtx.yaml
echo "        AdminPrincipal: Role.MEMBER" >> configtx.yaml

for ((i=1; i<=$NOP; i++))
do
	echo "    - &Org$i" >> configtx.yaml
	echo "        Name: Org"$i"MSP" >> configtx.yaml
	echo "        ID: Org"$i"MSP" >> configtx.yaml
	echo "        MSPDir: crypto-config/peerOrganizations/org$i.example.com/msp" >> configtx.yaml
	echo "        AdminPrincipal: Role.MEMBER" >> configtx.yaml
	echo "        AnchorPeers:" >> configtx.yaml
	echo "            - Host: blockchain-org"$i"peer1" >> configtx.yaml
	echo "              Port: 30"$i"10" >> configtx.yaml
done


##########################################################
# Updating Orderer Section
##########################################################

echo "################################################################################"  >> configtx.yaml
echo "#" >> configtx.yaml
echo "#   SECTION: Orderer" >> configtx.yaml
echo "#" >> configtx.yaml
echo "#   - This section defines the values to encode into a config transaction or" >> configtx.yaml
echo "#   genesis block for orderer related parameters" >> configtx.yaml
echo "#" >> configtx.yaml
echo "################################################################################" >> configtx.yaml

echo "Orderer: &OrdererDefaults" >> configtx.yaml
echo "    OrdererType: solo" >> configtx.yaml
echo "    Addresses:" >> configtx.yaml
echo "        - blockchain-orderer:31010" >> configtx.yaml
echo "    BatchTimeout: 2s" >> configtx.yaml
echo "    BatchSize:" >> configtx.yaml
echo "        MaxMessageCount: 10" >> configtx.yaml
echo "        AbsoluteMaxBytes: 99 MB" >> configtx.yaml
echo "        PreferredMaxBytes: 512 KB" >> configtx.yaml
echo "    Kafka:" >> configtx.yaml
echo "        Brokers:" >> configtx.yaml
echo "            - 127.0.0.1:9092" >> configtx.yaml
echo "    Organizations:" >> configtx.yaml

##########################################################
# Updating Application Section
##########################################################

echo "################################################################################" >> configtx.yaml
echo "#" >> configtx.yaml
echo "#   SECTION: Application" >> configtx.yaml
echo "#" >> configtx.yaml
echo "#   - This section defines the values to encode into a config transaction or" >> configtx.yaml
echo "#   genesis block for application related parameters" >> configtx.yaml
echo "#" >> configtx.yaml
echo "################################################################################" >> configtx.yaml

echo "Application: &ApplicationDefaults" >> configtx.yaml
echo "    Organizations:" >> configtx.yaml

popd >/dev/null 2>&1

##########################################################
# Updating service/definition files specific to Peer
##########################################################

pushd ibm-blockchain-network/templates/ >/dev/null 2>&1

for ((i=1; i<=$NOP; i++))
do
echo "
---
apiVersion: extensions/v1beta1
kind: Deployment
metadata:
  name: {{ template "ibm-blockchain-network.fullname" . }}-org"$i"peer1
  labels:
    app: {{ template "ibm-blockchain-network.name" . }}
    chart: {{ .Chart.Name }}-{{ .Chart.Version | replace "+" "_" }}
    release: {{ .Release.Name }}
    heritage: {{ .Release.Service }}
spec:
  replicas: 1
  template:
    metadata:
      name: {{ template "ibm-blockchain-network.fullname" . }}-org"$i"peer1
      labels:
        app: {{ template "ibm-blockchain-network.name" . }}
        chart: {{ .Chart.Name }}-{{ .Chart.Version | replace "+" "_" }}
        release: {{ .Release.Name }}
        heritage: {{ .Release.Service }}
        name: {{ template "ibm-blockchain-network.fullname" . }}-org"$i"peer1
    spec:
      volumes:
      - name: {{ template "ibm-blockchain-shared-pvc.name" . }}
        persistentVolumeClaim:
         claimName: {{ template "ibm-blockchain-shared-pvc.name" . }}
      - name: dockersocket
        hostPath:
          path: /var/run/docker.sock

      containers:
      - name: org"$i"peer1
        image: {{ .Values.blockchain.peerImage }}
        imagePullPolicy: {{ .Values.blockchain.pullPolicy }}
        command:
          - sh
          - -c
          - |
            sleep 1

            while [ ! -f /shared/bootstrapped ]; do
              echo Waiting for bootstrap
              sleep 1
            done

            touch /shared/status_org"$i"peer1_complete &&
            peer node start --peer-defaultchain=false
        env:
        - name: CORE_PEER_ADDRESSAUTODETECT
          value: "true"
        - name: CORE_PEER_NETWORKID
          value: nid1
        - name: CORE_PEER_ADDRESS
          value: {{ template "ibm-blockchain-network.name" . }}-org"$i"peer1:5010
        - name: CORE_PEER_LISTENADDRESS
          value: 0.0.0.0:5010
        - name: CORE_PEER_EVENTS_ADDRESS
          value: 0.0.0.0:5011
        - name: CORE_PEER_COMMITTER_ENABLED
          value: "true"
        - name: CORE_PEER_PROFILE_ENABLED
          value: "true"
        - name: CORE_PEER_DISCOVERY_PERIOD
          value: 60s
        - name: CORE_PEER_DISCOVERY_TOUCHPERIOD
          value: 60s
        - name: CORE_VM_ENDPOINT
          value: unix:///host/var/run/docker.sock
        - name: CORE_PEER_LOCALMSPID
          value: Org2MSP
        - name: CORE_PEER_MSPCONFIGPATH
          value: /shared/crypto-config/peerOrganizations/org"$i".example.com/peers/peer0.org"$i".example.com/msp/
        - name: CORE_LOGGING_LEVEL
          value: debug
        - name: CORE_LOGGING_PEER
          value: debug
        - name: CORE_LOGGING_CAUTHDSL
          value: debug
        - name: CORE_LOGGING_GOSSIP
          value: debug
        - name: CORE_LOGGING_LEDGER
          value: debug
        - name: CORE_LOGGING_MSP
          value: debug
        - name: CORE_LOGGING_POLICIES
          value: debug
        - name: CORE_LOGGING_GRPC
          value: debug
        - name: CORE_PEER_ID
          value: org"$i"peer1
        - name: CORE_PEER_TLS_ENABLED
          value: "false"
        - name: CORE_LEDGER_STATE_STATEDATABASE
          value: goleveldb
        - name: PEER_CFG_PATH
          value: peer_config/
        - name: FABRIC_CFG_PATH
          value: /etc/hyperledger/fabric/
        - name: ORDERER_URL
          value: {{ template "ibm-blockchain-network.name" . }}-orderer:31010
        - name: GODEBUG
          value: "netdns=go"
        volumeMounts:
        - mountPath: /shared
          name: {{ template "ibm-blockchain-shared-pvc.name" . }}
        - mountPath: /host/var/run/docker.sock
          name: dockersocket
" >> blockchain-org"$i"peer1.yaml

done

for ((i=1; i<=$NOP; i++))
do

echo "---
apiVersion: v1
kind: Service
metadata:
  name: {{ template "ibm-blockchain-network.name" . }}-org"$i"peer1
  labels:
    app: {{ template "ibm-blockchain-network.name" . }}
    chart: {{ .Chart.Name }}-{{ .Chart.Version | replace "+" "_" }}
    release: {{ .Release.Name }}
    heritage: {{ .Release.Service }}
    run: {{ template "ibm-blockchain-network.name" . }}-org"$i"peer1
spec:
  type: NodePort
  selector:
    name: {{ template "ibm-blockchain-network.name" . }}-org"$i"peer1
    app: {{ template "ibm-blockchain-network.name" . }}
    release: {{ .Release.Name }}
  ports:
  - protocol: TCP
    port: 5010
    nodePort: 30"$i"10
    name: grpc
  - protocol: TCP
    port: 5011
    nodePort: 30"$i"11
    name: events
" >> blockchain-org"$i"peer1-service.yaml

done


}

popd >/dev/null 2>&1

#
# lintChart: Lints the helm chart in the current working directory.
#
function lintChart() {
    LINT_OUTPUT=$(helm lint .)

    if [[ ${?} -ne 0 ]]; then
        colorEcho "\n$(basename $0): error: '$(basename $(pwd))' linting failed with errors:" 131
        colorEcho "${LINT_OUTPUT}" 131
        exit -1
    fi
}

#
# startNetwork: Starts the CA, orderer, and peer containers.
#
function startNetwork() {
    RELEASE_NAME="network"
    TOTAL_RUNNING=4
    TOTAL_COMPLETED=1

    # Move into the directory
    pushd ibm-blockchain-network >/dev/null 2>&1

    # Install the chart
    lintChart
    colorEcho "\n$ helm install --name ${RELEASE_NAME} ." 132
    helm install --name ${RELEASE_NAME} .

    # Ensure the correct number of pods are running and completed
    checkPodStatus ${TOTAL_RUNNING} ${TOTAL_COMPLETED}

    popd >/dev/null 2>&1
}

#
# Clean up and deploy the charts
#
checkDependencies
cleanEnvironment
generateNetwork
startNetwork
