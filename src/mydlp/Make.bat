@path %path%;C:\Program Files\erl5.7.4\bin
@set ERLC=erlc
@set ERLCARGS=-W -D__MYDLP_ENDPOINT -D__PLATFORM_WINDOWS

@set ERLSOURCES=mydlp.erl dynamic_compile.erl mydlp_acl.erl mydlp_logger_h.erl mydlp_acceptor.erl mydlp_loglevel.erl mydlp_sup.erl mydlp_matchers.erl mydlp_tc.erl mydlp_api.erl mydlp_app.erl mydlp_workdir.erl mydlp_worker_sup.erl mydlp_pg_sup.erl mydlp_dynamic.erl mydlp_regex.erl ..\thrift\gen-erl\mydlp_thrift.erl ..\thrift\gen-erl\mydlp_types.erl

@FOR %%s in (%ERLSOURCES%) do @(
	@echo Compiling %%s...
	@%ERLC% %ERLCARGS% %%s
)

@echo Creating mydlp.app from mydlp-ep.app...
@copy mydlp-ep.app mydlp.app

@echo Creating mydlp.rel from mydlp-ep.rel...
@copy mydlp-ep.rel mydlp.rel

@echo Generating boot scripts...
@%ERLC% -I. mydlp.rel
