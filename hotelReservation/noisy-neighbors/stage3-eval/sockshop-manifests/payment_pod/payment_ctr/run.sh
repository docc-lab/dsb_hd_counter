#!/bin/bash

WORKSPACE_NAME="payment_ctr"
WORKSPACE_DIR=$(pwd)

usage() { 
	echo "Usage: $0 [-h]" 1>&2
	echo "  Required environment variables:"
	
	if [ -z "${PAYMENT_SERVICE_GRPC_BIND_ADDR+x}" ]; then
		echo "    PAYMENT_SERVICE_GRPC_BIND_ADDR (missing)"
	else
		echo "    PAYMENT_SERVICE_GRPC_BIND_ADDR=$PAYMENT_SERVICE_GRPC_BIND_ADDR"
	fi
	if [ -z "${ZIPKIN_DIAL_ADDR+x}" ]; then
		echo "    ZIPKIN_DIAL_ADDR (missing)"
	else
		echo "    ZIPKIN_DIAL_ADDR=$ZIPKIN_DIAL_ADDR"
	fi
		
	exit 1; 
}

while getopts "h" flag; do
	case $flag in
		*)
		usage
		;;
	esac
done


payment_proc() {
	cd $WORKSPACE_DIR
	
	if [ -z "${ZIPKIN_DIAL_ADDR+x}" ]; then
		if ! zipkin_dial_addr; then
			return $?
		fi
	fi

	if [ -z "${PAYMENT_SERVICE_GRPC_BIND_ADDR+x}" ]; then
		if ! payment_service_grpc_bind_addr; then
			return $?
		fi
	fi

	run_payment_proc() {
		
        cd payment_proc
        ./payment_proc --zipkin.dial_addr=$ZIPKIN_DIAL_ADDR --payment_service.grpc.bind_addr=$PAYMENT_SERVICE_GRPC_BIND_ADDR &
        PAYMENT_PROC=$!
        return $?

	}

	if run_payment_proc; then
		if [ -z "${PAYMENT_PROC+x}" ]; then
			echo "${WORKSPACE_NAME} error starting payment_proc: function payment_proc did not set PAYMENT_PROC"
			return 1
		else
			echo "${WORKSPACE_NAME} started payment_proc"
			return 0
		fi
	else
		exitcode=$?
		echo "${WORKSPACE_NAME} aborting payment_proc due to exitcode ${exitcode} from payment_proc"
		return $exitcode
	fi
}


run_all() {
	echo "Running payment_ctr"

	# Check that all necessary environment variables are set
	echo "Required environment variables:"
	missing_vars=0
	if [ -z "${PAYMENT_SERVICE_GRPC_BIND_ADDR+x}" ]; then
		echo "  PAYMENT_SERVICE_GRPC_BIND_ADDR (missing)"
		missing_vars=$((missing_vars+1))
	else
		echo "  PAYMENT_SERVICE_GRPC_BIND_ADDR=$PAYMENT_SERVICE_GRPC_BIND_ADDR"
	fi
	
	if [ -z "${ZIPKIN_DIAL_ADDR+x}" ]; then
		echo "  ZIPKIN_DIAL_ADDR (missing)"
		missing_vars=$((missing_vars+1))
	else
		echo "  ZIPKIN_DIAL_ADDR=$ZIPKIN_DIAL_ADDR"
	fi
		

	if [ "$missing_vars" -gt 0 ]; then
		echo "Aborting due to missing environment variables"
		return 1
	fi

	payment_proc
	
	wait
}

run_all
