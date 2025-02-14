Q := @
PROJECT_ROOT := $(shell pwd)
SHELL := /bin/bash
BUILD_SUFFIX := extension
BUILD_DIR := $(PROJECT_ROOT)/tmp/build_$(BUILD_SUFFIX)
SO_FILE := $(BUILD_DIR)/modules/ddtrace.so
WALL_FLAGS := -Wall -Wextra
CFLAGS := -O2 $(WALL_FLAGS)
ROOT_DIR:=$(shell dirname $(realpath $(lastword $(MAKEFILE_LIST))))
PHP_MAJOR_MINOR:=$(shell php -r 'echo PHP_MAJOR_VERSION . PHP_MINOR_VERSION;')

VERSION:=$(shell awk -F\' '/const VERSION/ {print $$2}' < src/DDTrace/Tracer.php)

INI_FILE := $(shell php -i | awk -F"=>" '/Scan this dir for additional .ini files/ {print $$2}')/ddtrace.ini

C_FILES := $(shell find src/{dogstatsd,ext} -name '*.c' -o -name '*.h' | awk '{ printf "$(BUILD_DIR)/%s\n", $$1 }' )
TEST_FILES := $(shell find tests/ext -name '*.php*' -o -name '*.inc' | awk '{ printf "$(BUILD_DIR)/%s\n", $$1 }' )
M4_FILES := $(shell find m4 -name '*.m4*' | awk '{ printf "$(BUILD_DIR)/%s\n", $$1 }' )

ALL_FILES := $(C_FILES) $(TEST_FILES) $(BUILD_DIR)/config.m4 $(M4_FILES)

$(BUILD_DIR)/%: %
	$(Q) echo Copying $* to build dir
	$(Q) mkdir -p $(dir $@)
	$(Q) cp -a $* $@

JUNIT_RESULTS_DIR := $(shell pwd)

all: $(BUILD_DIR)/configure $(SO_FILE)

$(BUILD_DIR)/config.m4: $(M4_FILES)

$(BUILD_DIR)/configure: $(BUILD_DIR)/config.m4
	$(Q) (cd $(BUILD_DIR); phpize)

$(BUILD_DIR)/Makefile: $(BUILD_DIR)/configure
	$(Q) (cd $(BUILD_DIR); ./configure)

$(SO_FILE): $(ALL_FILES) $(BUILD_DIR)/Makefile
	$(Q) $(MAKE) -C $(BUILD_DIR) CFLAGS="$(CFLAGS)"

install: $(SO_FILE)
	$(Q) $(SUDO) $(MAKE) -C $(BUILD_DIR) install

$(INI_FILE):
	$(Q) echo "extension=ddtrace.so" | $(SUDO) tee -a $@

install_ini: $(INI_FILE)

install_all: install install_ini

test_c: export DD_TRACE_CLI_ENABLED=1
test_c: $(SO_FILE)
	set -xe; \
	export REPORT_EXIT_STATUS=1; \
	export TEST_PHP_SRCDIR=$(BUILD_DIR); \
	export USE_TRACKED_ALLOC=1; \
	\
	$(MAKE) -C $(BUILD_DIR) CFLAGS="-g" clean all; \
	php -n -d 'memory_limit=-1' $$TEST_PHP_SRCDIR/run-tests.php -n -p $$(which php) -d extension=$(SO_FILE) -q --show-all $(TESTS)

test_c_mem: export DD_TRACE_CLI_ENABLED=1
test_c_mem: $(SO_FILE)
	set -xe; \
	export REPORT_EXIT_STATUS=1; \
	export TEST_PHP_SRCDIR=$(BUILD_DIR); \
	export USE_TRACKED_ALLOC=1; \
	\
	$(MAKE) -C $(BUILD_DIR) CFLAGS="-g" clean all; \
	php -n -d 'memory_limit=-1' $$TEST_PHP_SRCDIR/run-tests.php -n -p $$(which php) -d extension=$(SO_FILE) -q --show-all -m $(TESTS)

test_c_asan: export DD_TRACE_CLI_ENABLED=1
test_c_asan: $(SO_FILE)
	( \
	set -xe; \
	export REPORT_EXIT_STATUS=1; \
	export TEST_PHP_SRCDIR=$(BUILD_DIR); \
	\
	export TEST_PHP_JUNIT=$(JUNIT_RESULTS_DIR)/asan-extension-test.xml; \
	$(MAKE) -C $(BUILD_DIR) CFLAGS="-g -fsanitize=address" LDFLAGS="-fsanitize=address" clean all; \
	php -n -d 'memory_limit=-1' $$TEST_PHP_SRCDIR/run-tests.php -n -p $$(which php) -d extension=$(SO_FILE) -q --show-all --asan $(TESTS); \
	)

test_extension_ci: $(SO_FILE)
	( \
	set -xe; \
	export REPORT_EXIT_STATUS=1; \
	export TEST_PHP_SRCDIR=$(BUILD_DIR); \
	\
	export TEST_PHP_JUNIT=$(JUNIT_RESULTS_DIR)/normal-extension-test.xml; \
	$(MAKE) -C $(BUILD_DIR) CFLAGS="-g" clean all; \
	php -n -d 'memory_limit=-1' $$TEST_PHP_SRCDIR/run-tests.php -n -p $$(which php) -d extension=$(SO_FILE) -q --show-all $(TESTS); \
	\
	export TEST_PHP_JUNIT=$(JUNIT_RESULTS_DIR)/valgrind-extension-test.xml; \
	export TEST_PHP_OUTPUT=$(JUNIT_RESULTS_DIR)/valgrind-run-tests.out; \
	php -n -d 'memory_limit=-1' $$TEST_PHP_SRCDIR/run-tests.php -n -p $$(which php) -d extension=$(SO_FILE) -q --show-all -m -s $$TEST_PHP_OUTPUT $(TESTS) && ! grep -e 'LEAKED TEST SUMMARY' $$TEST_PHP_OUTPUT; \
	)

dist_clean:
	rm -rf $(BUILD_DIR)

clean:
	$(MAKE) -C $(BUILD_DIR) clean
	$(Q) rm -f composer.lock

sudo:
	$(eval SUDO:=sudo)

debug:
	$(eval CFLAGS="-g")

strict:
	$(eval CFLAGS=-Wall -Werror -Wextra)

clang_find_files_to_lint:
	@find ./ \
	-path ./tmp -prune -o \
	-path ./vendor -prune -o \
	-path ./tests -prune -o \
	-path ./src/ext/mpack -prune -o \
	-path ./src/ext/third-party -prune -o \
	-iname "*.h" -o -iname "*.c" \
	-type f

CLANG_FORMAT := clang-format-6.0

clang_format_check:
	@while read fname; do \
		changes=$$($(CLANG_FORMAT) -output-replacements-xml $$fname | grep -c "<replacement " || true); \
		if [ $$changes != 0 ]; then \
			$(CLANG_FORMAT) -output-replacements-xml $$fname; \
			echo "$$fname did not pass clang-format, consider running: make clang_format_fix"; \
			touch .failure; \
		fi \
	done <<< $$($(MAKE) clang_find_files_to_lint)

clang_format_fix:
	$(MAKE) clang_find_files_to_lint | xargs clang-format -i

EXT_DIR:=/opt/datadog-php
PACKAGE_NAME:=datadog-php-tracer
FPM_INFO_OPTS=-a native -n $(PACKAGE_NAME) -m dev@datadoghq.com --license "BSD 3-Clause License" --version $(VERSION) \
	--provides $(PACKAGE_NAME) --vendor DataDog  --url "https://docs.datadoghq.com/tracing/setup/php/" --no-depends
FPM_DIR_OPTS=--directories $(EXT_DIR)/etc --config-files $(EXT_DIR)/etc -s dir
FPM_FILES=extensions/=$(EXT_DIR)/extensions \
	package/post-install.sh=$(EXT_DIR)/bin/post-install.sh package/ddtrace.ini.example=$(EXT_DIR)/etc/ \
	docs=$(EXT_DIR)/docs README.md=$(EXT_DIR)/docs/README.md UPGRADE-0.10.md=$(EXT_DIR)/docs/UPGRADE-0.10.md\
	src=$(EXT_DIR)/dd-trace-sources \
	bridge=$(EXT_DIR)/dd-trace-sources
FPM_OPTS=$(FPM_INFO_OPTS) $(FPM_DIR_OPTS) --after-install=package/post-install.sh

PACKAGES_BUILD_DIR:=build/packages

$(PACKAGES_BUILD_DIR):
	mkdir -p "$@"

.deb: $(PACKAGES_BUILD_DIR)
	fpm -p $(PACKAGES_BUILD_DIR) -t deb $(FPM_OPTS) $(FPM_FILES)
.rpm: $(PACKAGES_BUILD_DIR)
	fpm -p $(PACKAGES_BUILD_DIR) -t rpm $(FPM_OPTS) $(FPM_FILES)
.apk: $(PACKAGES_BUILD_DIR)
	fpm -p $(PACKAGES_BUILD_DIR) -t apk $(FPM_OPTS) --depends=bash --depends=curl --depends=libexecinfo $(FPM_FILES)
.tar.gz: $(PACKAGES_BUILD_DIR)
	fpm -p $(PACKAGES_BUILD_DIR)/$(PACKAGE_NAME)-$(VERSION).x86_64.tar.gz -t tar $(FPM_OPTS) $(FPM_FILES)

packages: .apk .rpm .deb .tar.gz
	tar -zcf packages.tar.gz $(PACKAGES_BUILD_DIR)

verify_pecl_file_definitions:
	@for i in $(C_FILES) $(TEST_FILES) $(M4_FILES); do\
		grep -q $${i#"$(BUILD_DIR)/"} package.xml && continue;\
		echo package.xml is missing \"$${i#"$(BUILD_DIR)/"}\"; \
		exit 1;\
	done
	@echo "PECL file definitions are correct"

verify_version:
	@grep -q "#define PHP_DDTRACE_VERSION \"$(VERSION)" src/ext/version.h || (echo src/ext/version.h Version missmatch && exit 1)
	@grep -q "const VERSION = '$(VERSION)" src/DDTrace/Tracer.php || (echo src/DDTrace/Tracer.php Version missmatch && exit 1)
	@echo "All version files match"

verify_all: verify_pecl_file_definitions verify_version

########################################################################################################################
# TESTS
########################################################################################################################
REQUEST_INIT_HOOK := -d ddtrace.request_init_hook=$(PROJECT_ROOT)/bridge/dd_wrap_autoloader.php
ENV_OVERRIDE := DD_TRACE_CLI_ENABLED=true

### DDTrace tests ###
TESTS_ROOT := ./tests
COMPOSER := COMPOSER_MEMORY_LIMIT=-1 composer --no-interaction
COMPOSER_TESTS := $(COMPOSER) --working-dir=$(TESTS_ROOT)
PHPUNIT_OPTS := $(PHPUNIT_OPTS)
PHPUNIT := $(TESTS_ROOT)/vendor/bin/phpunit $(PHPUNIT_OPTS) --config=$(TESTS_ROOT)/phpunit.xml

TEST_INTEGRATIONS_54 := \
	test_integrations_curl \
	test_integrations_memcached \
	test_integrations_mysqli \
	test_integrations_pdo \
	test_integrations_elasticsearch1 \
	test_integrations_guzzle5 \
	test_integrations_predis1

TEST_WEB_54 := \
	test_metrics \
	test_web_cakephp_28 \
	test_web_laravel_42 \
	test_web_yii_2 \
	test_web_zend_1 \
	test_web_custom

TEST_INTEGRATIONS_55 := \
	test_integrations_curl \
	test_integrations_memcached \
	test_integrations_mysqli \
	test_integrations_mongo \
	test_integrations_pdo \
	test_integrations_elasticsearch1 \
	test_integrations_guzzle5 \
	test_integrations_guzzle6 \
	test_integrations_predis1

TEST_WEB_55 := \
	test_metrics \
	test_web_cakephp_28 \
	test_web_codeigniter_22 \
	test_web_laravel_42 \
	test_web_lumen_52 \
	test_web_slim_312 \
	test_web_symfony_23 \
	test_web_symfony_28 \
	test_web_symfony_30 \
	test_web_symfony_33 \
	test_web_symfony_34 \
	test_web_yii_2 \
	test_web_wordpress_48 \
	test_web_zend_1 \
	test_web_custom

TEST_INTEGRATIONS_56 := \
	test_integrations_curl \
	test_integrations_memcached \
	test_integrations_mysqli \
	test_integrations_mongo \
	test_integrations_pdo \
	test_integrations_elasticsearch1 \
	test_integrations_guzzle5 \
	test_integrations_guzzle6 \
	test_integrations_predis1

TEST_WEB_56 := \
	test_metrics \
	test_web_cakephp_28 \
	test_web_codeigniter_22 \
	test_web_laravel_42 \
	test_web_lumen_52 \
	test_web_slim_312 \
	test_web_symfony_23 \
	test_web_symfony_28 \
	test_web_symfony_30 \
	test_web_symfony_33 \
	test_web_symfony_34 \
	test_web_yii_2 \
	test_web_wordpress_48 \
	test_web_zend_1 \
	test_web_custom

TEST_INTEGRATIONS_70 := \
	test_integrations_curl \
	test_integrations_memcached \
	test_integrations_mysqli \
	test_integrations_pdo \
	test_integrations_elasticsearch1 \
	test_integrations_guzzle5 \
	test_integrations_guzzle6 \
	test_integrations_phpredis3 \
	test_integrations_phpredis4 \
	test_integrations_phpredis5 \
	test_integrations_predis1

TEST_WEB_70 := \
	test_metrics \
	test_web_cakephp_28 \
	test_web_codeigniter_22 \
	test_web_laravel_42 \
	test_web_lumen_52 \
	test_web_slim_312 \
	test_web_symfony_23 \
	test_web_symfony_28 \
	test_web_symfony_30 \
	test_web_symfony_33 \
	test_web_symfony_34 \
	test_web_yii_2 \
	test_web_wordpress_48 \
	test_web_zend_1 \
	test_web_custom

TEST_INTEGRATIONS_71 := \
	test_integrations_curl \
	test_integrations_memcached \
	test_integrations_mysqli \
	test_integrations_pdo \
	test_integrations_elasticsearch1 \
	test_integrations_guzzle5 \
	test_integrations_guzzle6 \
	test_integrations_phpredis3 \
	test_integrations_phpredis4 \
	test_integrations_phpredis5 \
	test_integrations_predis1

TEST_WEB_71 := \
	test_metrics \
	test_web_cakephp_28 \
	test_web_codeigniter_22 \
	test_web_laravel_42 \
	test_web_laravel_57 \
	test_web_laravel_58 \
	test_web_lumen_52 \
	test_web_lumen_56 \
	test_web_lumen_58 \
	test_web_slim_312 \
	test_web_symfony_23 \
	test_web_symfony_28 \
	test_web_symfony_30 \
	test_web_symfony_33 \
	test_web_symfony_34 \
	test_web_symfony_42 \
	test_web_yii_2 \
	test_web_wordpress_48 \
	test_web_zend_1 \
	test_web_custom \
	test_opentracing_10

TEST_INTEGRATIONS_72 := \
	test_integrations_curl \
	test_integrations_memcached \
	test_integrations_mysqli \
	test_integrations_pdo \
	test_integrations_elasticsearch1 \
	test_integrations_guzzle5 \
	test_integrations_guzzle6 \
	test_integrations_phpredis3 \
	test_integrations_phpredis4 \
	test_integrations_phpredis5 \
	test_integrations_predis1

TEST_WEB_72 := \
	test_metrics \
	test_web_codeigniter_22 \
	test_web_laravel_42 \
	test_web_laravel_57 \
	test_web_laravel_58 \
	test_web_lumen_52 \
	test_web_lumen_56 \
	test_web_lumen_58 \
	test_web_slim_312 \
	test_web_symfony_23 \
	test_web_symfony_28 \
	test_web_symfony_30 \
	test_web_symfony_33 \
	test_web_symfony_34 \
	test_web_symfony_40 \
	test_web_symfony_42 \
	test_web_symfony_44 \
	test_web_wordpress_48 \
	test_web_yii_2 \
	test_web_zend_1 \
	test_web_custom \
	test_opentracing_10

TEST_INTEGRATIONS_73 :=\
	test_integrations_curl \
	test_integrations_memcached \
	test_integrations_mysqli \
	test_integrations_pdo \
	test_integrations_guzzle5 \
	test_integrations_guzzle6 \
	test_integrations_phpredis3 \
	test_integrations_phpredis4 \
	test_integrations_phpredis5 \
	test_integrations_predis1

TEST_WEB_73 := \
	test_metrics \
	test_web_codeigniter_22 \
	test_web_laravel_57 \
	test_web_laravel_58 \
	test_web_lumen_52 \
	test_web_lumen_56 \
	test_web_lumen_58 \
	test_web_slim_312 \
	test_web_symfony_40 \
	test_web_symfony_42 \
	test_web_symfony_44 \
	test_web_wordpress_48 \
	test_web_yii_2 \
	test_web_zend_1 \
	test_web_custom \
	test_opentracing_10

TEST_INTEGRATIONS_74 := \
	test_integrations_curl \
	test_integrations_memcached \
	test_integrations_mysqli \
	test_integrations_pdo \
	test_integrations_guzzle5 \
	test_integrations_guzzle6 \
	test_integrations_phpredis3 \
	test_integrations_phpredis4 \
	test_integrations_phpredis5 \
	test_integrations_predis1

TEST_WEB_74 := \
	test_metrics \
	test_web_codeigniter_22 \
	test_web_laravel_57 \
	test_web_laravel_58 \
	test_web_lumen_52 \
	test_web_lumen_56 \
	test_web_lumen_58 \
	test_web_slim_312 \
	test_web_symfony_40 \
	test_web_symfony_42 \
	test_web_symfony_44 \
	test_web_wordpress_48 \
	test_web_yii_2 \
	test_web_zend_1 \
	test_web_custom \
	test_opentracing_10

define run_tests
	$(ENV_OVERRIDE) php $(REQUEST_INIT_HOOK) $(PHPUNIT) $(1)
endef

# use this as the first target if you want to use uncompiled files instead of the _generated.php compiled file.
dev:
	$(Q) :
	$(Q) $(eval ENV_OVERRIDE:=$(ENV_OVERRIDE) DD_AUTOLOAD_NO_COMPILE=true)

clean_test: clean_test_scenarios
	rm -rf $(TESTS_ROOT)/composer.lock $(TESTS_ROOT)/.scenarios.lock $(TESTS_ROOT)/vendor
	find $(TESTS_ROOT)/Frameworks/ -path "*/vendor/*" -prune -o -wholename "*/cache/*.php" -print -exec rm -rf {} \;

clean_test_scenarios:
	$(TESTS_ROOT)/clean-composer-scenario-locks.sh

composer_tests_update:
	$(COMPOSER_TESTS) update

test_all: \
	test_unit \
	test_integration \
	test_auto_instrumentation \
	test_composer \
	test_distributed_tracing
	test_integrations \
	test_web

test:
	$(call run_tests,$(TESTS))

test_unit:
	$(call run_tests,--testsuite=unit $(TESTS))

test_integration:
	$(call run_tests,--testsuite=integration $(TESTS))

test_auto_instrumentation:
	$(call run_tests,--testsuite=auto-instrumentation $(TESTS))
	# Cleaning up composer.json files in tests/AutoInstrumentation modified for TLS during tests
	git checkout $(TESTS_ROOT)/AutoInstrumentation/**/composer.json

test_composer:
	$(call run_tests,--testsuite=composer-tests $(TESTS))

test_distributed_tracing:
	$(call run_tests,--testsuite=distributed-tracing $(TESTS))

test_metrics:
	$(call run_tests,--testsuite=metrics $(TESTS))

test_opentracing_10:
	$(MAKE) test_scenario_opentracing1
	$(call run_tests,tests/OpenTracerUnit)

test_integrations: $(TEST_INTEGRATIONS_$(PHP_MAJOR_MINOR))
test_web: $(TEST_WEB_$(PHP_MAJOR_MINOR))

test_integrations_curl:
	$(call run_tests,tests/Integrations/Curl)
test_integrations_elasticsearch1:
	$(MAKE) test_scenario_elasticsearch1
	$(call run_tests,tests/Integrations/Elasticsearch)
test_integrations_guzzle5:
	$(MAKE) test_scenario_guzzle5
	$(call run_tests,tests/Integrations/Guzzle/V5)
test_integrations_guzzle6:
	$(MAKE) test_scenario_guzzle6
	$(call run_tests,tests/Integrations/Guzzle/V6)
test_integrations_memcached:
	$(MAKE) test_scenario_default
	$(call run_tests,tests/Integrations/Memcached)
test_integrations_mysqli:
	$(MAKE) test_scenario_default
	$(call run_tests,tests/Integrations/Mysqli)
test_integrations_mongo:
	$(MAKE) test_scenario_default
	$(call run_tests,tests/Integrations/Mongo)
test_integrations_pdo:
	$(MAKE) test_scenario_default
	$(call run_tests,tests/Integrations/PDO)
test_integrations_phpredis3:
	$(MAKE) test_scenario_phpredis3
	$(call run_tests,tests/Integrations/PHPRedis/PHPRedis3Test.php)
test_integrations_phpredis4:
	$(MAKE) test_scenario_phpredis4
	$(call run_tests,tests/Integrations/PHPRedis/PHPRedis4Test.php)
test_integrations_phpredis5:
	$(MAKE) test_scenario_phpredis5
	$(call run_tests,tests/Integrations/PHPRedis/PHPRedis5Test.php)
test_integrations_predis1:
	$(MAKE) test_scenario_predis1
	$(call run_tests,tests/Integrations/Predis)
test_web_cakephp_28:
	$(COMPOSER) --working-dir=tests/Frameworks/CakePHP/Version_2_8 update
	$(call run_tests,--testsuite=cakephp-28-test)
test_web_codeigniter_22:
	$(call run_tests,--testsuite=codeigniter-22-test)
test_web_laravel_42:
	$(COMPOSER) --working-dir=tests/Frameworks/Laravel/Version_4_2 update
	php tests/Frameworks/Laravel/Version_4_2/artisan optimize
	$(call run_tests,tests/Integrations/Laravel/V4)
test_web_laravel_57:
	$(COMPOSER) --working-dir=tests/Frameworks/Laravel/Version_5_7 update
	$(call run_tests,tests/Integrations/Laravel/V5_7)
test_web_laravel_58:
	$(COMPOSER) --working-dir=tests/Frameworks/Laravel/Version_5_8 update
	$(call run_tests,--testsuite=laravel-58-test)
test_web_lumen_52:
	$(COMPOSER) --working-dir=tests/Frameworks/Lumen/Version_5_2 update
	$(call run_tests,tests/Integrations/Lumen/V5_2)
test_web_lumen_56:
	$(COMPOSER) --working-dir=tests/Frameworks/Lumen/Version_5_6 update
	$(call run_tests,tests/Integrations/Lumen/V5_6)
test_web_lumen_58:
	$(COMPOSER) --working-dir=tests/Frameworks/Lumen/Version_5_8 update
	$(call run_tests,tests/Integrations/Lumen/V5_8)
test_web_slim_312:
	$(COMPOSER) --working-dir=tests/Frameworks/Slim/Version_3_12 update
	$(call run_tests,--testsuite=slim-312-test)
test_web_symfony_23:
	$(COMPOSER) --working-dir=tests/Frameworks/Symfony/Version_2_3 update
	$(call run_tests,tests/Integrations/Symfony/V2_3)
test_web_symfony_28:
	$(COMPOSER) --working-dir=tests/Frameworks/Symfony/Version_2_8 update
	$(call run_tests,tests/Integrations/Symfony/V2_8)
test_web_symfony_30:
	$(COMPOSER) --working-dir=tests/Frameworks/Symfony/Version_3_0 update
	php tests/Frameworks/Symfony/Version_3_0/bin/console cache:clear --no-warmup --env=prod
	$(call run_tests,tests/Integrations/Symfony/V3_0)
test_web_symfony_33:
	$(COMPOSER) --working-dir=tests/Frameworks/Symfony/Version_3_3 update
	php tests/Frameworks/Symfony/Version_3_3/bin/console cache:clear --no-warmup --env=prod
	$(call run_tests,tests/Integrations/Symfony/V3_3)
test_web_symfony_34:
	$(COMPOSER) --working-dir=tests/Frameworks/Symfony/Version_3_4 update
	php tests/Frameworks/Symfony/Version_3_4/bin/console cache:clear --no-warmup --env=prod
	$(call run_tests,tests/Integrations/Symfony/V3_4)
test_web_symfony_40:
	# Trick to have symfony 4.0 update process not to fail because of an error related to monolog dependencies.
	$(COMPOSER) --working-dir=tests/Frameworks/Symfony/Version_4_0 update --no-scripts
	$(COMPOSER) --working-dir=tests/Frameworks/Symfony/Version_4_0 update
	php tests/Frameworks/Symfony/Version_4_0/bin/console cache:clear --no-warmup --env=prod
	$(call run_tests,tests/Integrations/Symfony/V4_0)
test_web_symfony_42:
	$(COMPOSER) --working-dir=tests/Frameworks/Symfony/Version_4_2 update
	php tests/Frameworks/Symfony/Version_4_2/bin/console cache:clear --no-warmup --env=prod
	$(call run_tests,tests/Integrations/Symfony/V4_2)
test_web_symfony_44:
	$(COMPOSER) --working-dir=tests/Frameworks/Symfony/Version_4_4 update
	php tests/Frameworks/Symfony/Version_4_4/bin/console cache:clear --no-warmup --env=prod
	$(call run_tests,tests/Integrations/Symfony/V4_4)
test_web_wordpress_48:
	$(call run_tests,tests/Integrations/WordPress/V4_8)
test_web_yii_2:
	$(COMPOSER) --working-dir=tests/Frameworks/Yii/Version_2_0_26 update
	$(call run_tests,tests/Integrations/Yii/V2_0_26)
test_web_zend_1:
	$(call run_tests,tests/Integrations/ZendFramework/V1)
test_web_custom:
	$(COMPOSER) --working-dir=tests/Frameworks/Custom/Version_Autoloaded update
	$(call run_tests,--testsuite=custom-framework-autoloading-test)

test_scenario_%:
	$(Q) $(COMPOSER_TESTS) scenario $*

### Api tests ###
API_TESTS_ROOT := ./tests/api

test_api_unit: composer.lock
	$(ENV_OVERRIDE) php $(REQUEST_INIT_HOOK) vendor/bin/phpunit --config=phpunit.xml $(API_TESTS_ROOT)/Unit $(TESTS)

composer.lock: composer.json
	$(Q) composer update

.PHONY: dev dist_clean clean all clang_format_check clang_format_fix install sudo_install test_c test_c_mem test_extension_ci test install_ini install_all \
	.apk .rpm .deb .tar.gz sudo debug strict run-tests.php verify_pecl_file_definitions verify_version verify_package_xml verify_all
