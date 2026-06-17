#!/bin/bash

WORKSPACE_NAME="order_ctr"
WORKSPACE_DIR=$(pwd)

usage() { 
	echo "Usage: $0 [-h]" 1>&2
	echo "  Required environment variables:"
	
	if [ -z "${CART_SERVICE_GRPC_DIAL_ADDR+x}" ]; then
		echo "    CART_SERVICE_GRPC_DIAL_ADDR (missing)"
	else
		echo "    CART_SERVICE_GRPC_DIAL_ADDR=$CART_SERVICE_GRPC_DIAL_ADDR"
	fi
	if [ -z "${ORDER_DB_DIAL_ADDR+x}" ]; then
		echo "    ORDER_DB_DIAL_ADDR (missing)"
	else
		echo "    ORDER_DB_DIAL_ADDR=$ORDER_DB_DIAL_ADDR"
	fi
	if [ -z "${ORDER_SERVICE_GRPC_BIND_ADDR+x}" ]; then
		echo "    ORDER_SERVICE_GRPC_BIND_ADDR (missing)"
	else
		echo "    ORDER_SERVICE_GRPC_BIND_ADDR=$ORDER_SERVICE_GRPC_BIND_ADDR"
	fi
	if [ -z "${PAYMENT_SERVICE_GRPC_DIAL_ADDR+x}" ]; then
		echo "    PAYMENT_SERVICE_GRPC_DIAL_ADDR (missing)"
	else
		echo "    PAYMENT_SERVICE_GRPC_DIAL_ADDR=$PAYMENT_SERVICE_GRPC_DIAL_ADDR"
	fi
	if [ -z "${SHIPPING_SERVICE_GRPC_DIAL_ADDR+x}" ]; then
		echo "    SHIPPING_SERVICE_GRPC_DIAL_ADDR (missing)"
	else
		echo "    SHIPPING_SERVICE_GRPC_DIAL_ADDR=$SHIPPING_SERVICE_GRPC_DIAL_ADDR"
	fi
	if [ -z "${USER_SERVICE_GRPC_DIAL_ADDR+x}" ]; then
		echo "    USER_SERVICE_GRPC_DIAL_ADDR (missing)"
	else
		echo "    USER_SERVICE_GRPC_DIAL_ADDR=$USER_SERVICE_GRPC_DIAL_ADDR"
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


order_proc() {
	cd $WORKSPACE_DIR
	
	if [ -z "${USER_SERVICE_GRPC_DIAL_ADDR+x}" ]; then
		if ! user_service_grpc_dial_addr; then
			return $?
		fi
	fi

	if [ -z "${ZIPKIN_DIAL_ADDR+x}" ]; then
		if ! zipkin_dial_addr; then
			return $?
		fi
	fi

	if [ -z "${CART_SERVICE_GRPC_DIAL_ADDR+x}" ]; then
		if ! cart_service_grpc_dial_addr; then
			return $?
		fi
	fi

	if [ -z "${PAYMENT_SERVICE_GRPC_DIAL_ADDR+x}" ]; then
		if ! payment_service_grpc_dial_addr; then
			return $?
		fi
	fi

	if [ -z "${SHIPPING_SERVICE_GRPC_DIAL_ADDR+x}" ]; then
		if ! shipping_service_grpc_dial_addr; then
			return $?
		fi
	fi

	if [ -z "${ORDER_DB_DIAL_ADDR+x}" ]; then
		if ! order_db_dial_addr; then
			return $?
		fi
	fi

	if [ -z "${ORDER_SERVICE_GRPC_BIND_ADDR+x}" ]; then
		if ! order_service_grpc_bind_addr; then
			return $?
		fi
	fi

	run_order_proc() {
		
        cd order_proc
        ./order_proc --user_service.grpc.dial_addr=$USER_SERVICE_GRPC_DIAL_ADDR --zipkin.dial_addr=$ZIPKIN_DIAL_ADDR --cart_service.grpc.dial_addr=$CART_SERVICE_GRPC_DIAL_ADDR --payment_service.grpc.dial_addr=$PAYMENT_SERVICE_GRPC_DIAL_ADDR --shipping_service.grpc.dial_addr=$SHIPPING_SERVICE_GRPC_DIAL_ADDR --order_db.dial_addr=$ORDER_DB_DIAL_ADDR --order_service.grpc.bind_addr=$ORDER_SERVICE_GRPC_BIND_ADDR &
        ORDER_PROC=$!
        return $?

	}

	if run_order_proc; then
		if [ -z "${ORDER_PROC+x}" ]; then
			echo "${WORKSPACE_NAME} error starting order_proc: function order_proc did not set ORDER_PROC"
			return 1
		else
			echo "${WORKSPACE_NAME} started order_proc"
			return 0
		fi
	else
		exitcode=$?
		echo "${WORKSPACE_NAME} aborting order_proc due to exitcode ${exitcode} from order_proc"
		return $exitcode
	fi
}


run_all() {
	echo "Running order_ctr"

	# Check that all necessary environment variables are set
	echo "Required environment variables:"
	missing_vars=0
	if [ -z "${CART_SERVICE_GRPC_DIAL_ADDR+x}" ]; then
		echo "  CART_SERVICE_GRPC_DIAL_ADDR (missing)"
		missing_vars=$((missing_vars+1))
	else
		echo "  CART_SERVICE_GRPC_DIAL_ADDR=$CART_SERVICE_GRPC_DIAL_ADDR"
	fi
	
	if [ -z "${ORDER_DB_DIAL_ADDR+x}" ]; then
		echo "  ORDER_DB_DIAL_ADDR (missing)"
		missing_vars=$((missing_vars+1))
	else
		echo "  ORDER_DB_DIAL_ADDR=$ORDER_DB_DIAL_ADDR"
	fi
	
	if [ -z "${ORDER_SERVICE_GRPC_BIND_ADDR+x}" ]; then
		echo "  ORDER_SERVICE_GRPC_BIND_ADDR (missing)"
		missing_vars=$((missing_vars+1))
	else
		echo "  ORDER_SERVICE_GRPC_BIND_ADDR=$ORDER_SERVICE_GRPC_BIND_ADDR"
	fi
	
	if [ -z "${PAYMENT_SERVICE_GRPC_DIAL_ADDR+x}" ]; then
		echo "  PAYMENT_SERVICE_GRPC_DIAL_ADDR (missing)"
		missing_vars=$((missing_vars+1))
	else
		echo "  PAYMENT_SERVICE_GRPC_DIAL_ADDR=$PAYMENT_SERVICE_GRPC_DIAL_ADDR"
	fi
	
	if [ -z "${SHIPPING_SERVICE_GRPC_DIAL_ADDR+x}" ]; then
		echo "  SHIPPING_SERVICE_GRPC_DIAL_ADDR (missing)"
		missing_vars=$((missing_vars+1))
	else
		echo "  SHIPPING_SERVICE_GRPC_DIAL_ADDR=$SHIPPING_SERVICE_GRPC_DIAL_ADDR"
	fi
	
	if [ -z "${USER_SERVICE_GRPC_DIAL_ADDR+x}" ]; then
		echo "  USER_SERVICE_GRPC_DIAL_ADDR (missing)"
		missing_vars=$((missing_vars+1))
	else
		echo "  USER_SERVICE_GRPC_DIAL_ADDR=$USER_SERVICE_GRPC_DIAL_ADDR"
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

	order_proc
	
	wait
}

run_all
