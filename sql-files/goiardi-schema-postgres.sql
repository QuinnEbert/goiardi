--
-- PostgreSQL database dump
--

SET statement_timeout = 0;
SET lock_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SET check_function_bodies = false;
SET client_min_messages = warning;

--
-- Name: goiardi; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA goiardi;


--
-- Name: sqitch; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA sqitch;


--
-- Name: SCHEMA sqitch; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON SCHEMA sqitch IS 'Sqitch database deployment metadata v1.0.';


--
-- Name: plpgsql; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS plpgsql WITH SCHEMA pg_catalog;


--
-- Name: EXTENSION plpgsql; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION plpgsql IS 'PL/pgSQL procedural language';


--
-- Name: ltree; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS ltree WITH SCHEMA goiardi;


--
-- Name: EXTENSION ltree; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION ltree IS 'data type for hierarchical tree-like structures';


--
-- Name: pg_trgm; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS pg_trgm WITH SCHEMA goiardi;


--
-- Name: EXTENSION pg_trgm; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION pg_trgm IS 'text similarity measurement and index searching based on trigrams';


SET search_path = goiardi, pg_catalog;

--
-- Name: log_action; Type: TYPE; Schema: goiardi; Owner: -
--

CREATE TYPE log_action AS ENUM (
    'create',
    'delete',
    'modify'
);


--
-- Name: log_actor; Type: TYPE; Schema: goiardi; Owner: -
--

CREATE TYPE log_actor AS ENUM (
    'user',
    'client'
);


--
-- Name: report_status; Type: TYPE; Schema: goiardi; Owner: -
--

CREATE TYPE report_status AS ENUM (
    'started',
    'success',
    'failure'
);


--
-- Name: shovey_output; Type: TYPE; Schema: goiardi; Owner: -
--

CREATE TYPE shovey_output AS ENUM (
    'stdout',
    'stderr'
);


--
-- Name: status_node; Type: TYPE; Schema: goiardi; Owner: -
--

CREATE TYPE status_node AS ENUM (
    'new',
    'up',
    'down'
);


--
-- Name: delete_search_collection(text, integer); Type: FUNCTION; Schema: goiardi; Owner: -
--

CREATE FUNCTION delete_search_collection(col text, m_organization_id integer) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
	sc_id bigint;
BEGIN
	SELECT id INTO sc_id FROM goiardi.search_collections WHERE name = col AND organization_id = m_organization_id;
	IF NOT FOUND THEN
		RAISE EXCEPTION 'The collection % does not exist!', col;
	END IF;
	DELETE FROM goiardi.search_items WHERE organization_id = m_organization_id AND search_collection_id = sc_id;
	DELETE FROM goiardi.search_collections WHERE organization_id = m_organization_id AND id = sc_id;
END;
$$;


--
-- Name: delete_search_item(text, text, integer); Type: FUNCTION; Schema: goiardi; Owner: -
--

CREATE FUNCTION delete_search_item(col text, item text, m_organization_id integer) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
	sc_id bigint;
BEGIN
	SELECT id INTO sc_id FROM goiardi.search_collections WHERE name = col AND organization_id = m_organization_id;
	IF NOT FOUND THEN
		RAISE EXCEPTION 'The collection % does not exist!', col;
	END IF;
	DELETE FROM goiardi.search_items WHERE organization_id = m_organization_id AND search_collection_id = sc_id AND item_name = item;
END;
$$;


--
-- Name: insert_dbi(text, text, text, bigint, json); Type: FUNCTION; Schema: goiardi; Owner: -
--

CREATE FUNCTION insert_dbi(m_data_bag_name text, m_name text, m_orig_name text, m_dbag_id bigint, m_raw_data json) RETURNS bigint
    LANGUAGE plpgsql
    AS $$
DECLARE
	u BIGINT;
	dbi_id BIGINT;
BEGIN
	SELECT id INTO u FROM goiardi.data_bags WHERE id = m_dbag_id;
	IF NOT FOUND THEN
		RAISE EXCEPTION 'aiiiie! The data bag % was deleted from the db while we were doing something else', m_data_bag_name;
	END IF;

	INSERT INTO goiardi.data_bag_items (name, orig_name, data_bag_id, raw_data, created_at, updated_at) VALUES (m_name, m_orig_name, m_dbag_id, m_raw_data, NOW(), NOW()) RETURNING id INTO dbi_id;
	RETURN dbi_id;
END;
$$;


--
-- Name: insert_node_status(text, status_node); Type: FUNCTION; Schema: goiardi; Owner: -
--

CREATE FUNCTION insert_node_status(m_name text, m_status status_node) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
	n BIGINT;
BEGIN
	SELECT id INTO n FROM goiardi.nodes WHERE name = m_name;
	IF NOT FOUND THEN
		RAISE EXCEPTION 'aiiie, the node % was deleted while we were doing something else trying to insert a status', m_name;
	END IF;
	INSERT INTO goiardi.node_statuses (node_id, status, updated_at) VALUES (n, m_status, NOW());
	RETURN;
END;
$$;


--
-- Name: merge_clients(text, text, boolean, boolean, text, text); Type: FUNCTION; Schema: goiardi; Owner: -
--

CREATE FUNCTION merge_clients(m_name text, m_nodename text, m_validator boolean, m_admin boolean, m_public_key text, m_certificate text) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
    u_id bigint;
    u_name text;
BEGIN
    SELECT id, name INTO u_id, u_name FROM goiardi.users WHERE name = m_name;
    IF FOUND THEN
        RAISE EXCEPTION 'a user with id % named % was found that would conflict with this client', u_id, u_name;
    END IF;
    LOOP
        -- first try to update the key
        UPDATE goiardi.clients SET name = m_name, nodename = m_nodename, validator = m_validator, admin = m_admin, public_key = m_public_key, certificate = m_certificate, updated_at = NOW() WHERE name = m_name;
        IF found THEN
            RETURN;
        END IF;
        -- not there, so try to insert the key
        -- if someone else inserts the same key concurrently,
        -- we could get a unique-key failure
        BEGIN
            INSERT INTO goiardi.clients (name, nodename, validator, admin, public_key, certificate, created_at, updated_at) VALUES (m_name, m_nodename, m_validator, m_admin, m_public_key, m_certificate, NOW(), NOW());
            RETURN;
        EXCEPTION WHEN unique_violation THEN
            -- Do nothing, and loop to try the UPDATE again.
        END;
    END LOOP;
END;
$$;


--
-- Name: merge_cookbook_versions(bigint, boolean, json, json, json, json, json, json, json, json, json, json, bigint, bigint, bigint); Type: FUNCTION; Schema: goiardi; Owner: -
--

CREATE FUNCTION merge_cookbook_versions(c_id bigint, is_frozen boolean, defb json, libb json, attb json, recb json, prob json, resb json, temb json, roob json, filb json, metb json, maj bigint, min bigint, patch bigint) RETURNS bigint
    LANGUAGE plpgsql
    AS $$
DECLARE
    cbv_id BIGINT;
BEGIN
    LOOP
        -- first try to update the key
        UPDATE goiardi.cookbook_versions SET frozen = is_frozen, metadata = metb, definitions = defb, libraries = libb, attributes = attb, recipes = recb, providers = prob, resources = resb, templates = temb, root_files = roob, files = filb, updated_at = NOW() WHERE cookbook_id = c_id AND major_ver = maj AND minor_ver = min AND patch_ver = patch RETURNING id INTO cbv_id;
        IF found THEN
            RETURN cbv_id;
        END IF;
        -- not there, so try to insert the key
        -- if someone else inserts the same key concurrently,
        -- we could get a unique-key failure
        BEGIN
            INSERT INTO goiardi.cookbook_versions (cookbook_id, major_ver, minor_ver, patch_ver, frozen, metadata, definitions, libraries, attributes, recipes, providers, resources, templates, root_files, files, created_at, updated_at) VALUES (c_id, maj, min, patch, is_frozen, metb, defb, libb, attb, recb, prob, resb, temb, roob, filb, NOW(), NOW()) RETURNING id INTO cbv_id;
            RETURN c_id;
        EXCEPTION WHEN unique_violation THEN
            -- Do nothing, and loop to try the UPDATE again.
        END;
    END LOOP;
END;
$$;


--
-- Name: merge_cookbooks(text); Type: FUNCTION; Schema: goiardi; Owner: -
--

CREATE FUNCTION merge_cookbooks(m_name text) RETURNS bigint
    LANGUAGE plpgsql
    AS $$
DECLARE
    c_id BIGINT;
BEGIN
    LOOP
        -- first try to update the key
        UPDATE goiardi.cookbooks SET name = m_name, updated_at = NOW() WHERE name = m_name RETURNING id INTO c_id;
        IF found THEN
            RETURN c_id;
        END IF;
        -- not there, so try to insert the key
        -- if someone else inserts the same key concurrently,
        -- we could get a unique-key failure
        BEGIN
            INSERT INTO goiardi.cookbooks (name, created_at, updated_at) VALUES (m_name, NOW(), NOW()) RETURNING id INTO c_id;
            RETURN c_id;
        EXCEPTION WHEN unique_violation THEN
            -- Do nothing, and loop to try the UPDATE again.
        END;
    END LOOP;
END;
$$;


--
-- Name: merge_data_bags(text); Type: FUNCTION; Schema: goiardi; Owner: -
--

CREATE FUNCTION merge_data_bags(m_name text) RETURNS bigint
    LANGUAGE plpgsql
    AS $$
DECLARE
    db_id BIGINT;
BEGIN
    LOOP
        -- first try to update the key
        UPDATE goiardi.data_bags SET updated_at = NOW() WHERE name = m_name RETURNING id INTO db_id;
        IF found THEN
            RETURN db_id;
        END IF;
        -- not there, so try to insert the key
        -- if someone else inserts the same key concurrently,
        -- we could get a unique-key failure
        BEGIN
            INSERT INTO goiardi.data_bags (name, created_at, updated_at) VALUES (m_name, NOW(), NOW()) RETURNING id INTO db_id;
            RETURN db_id;
        EXCEPTION WHEN unique_violation THEN
            -- Do nothing, and loop to try the UPDATE again.
        END;
    END LOOP;
END;
$$;


--
-- Name: merge_environments(text, text, json, json, json); Type: FUNCTION; Schema: goiardi; Owner: -
--

CREATE FUNCTION merge_environments(m_name text, m_description text, m_default_attr json, m_override_attr json, m_cookbook_vers json) RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN
    LOOP
        -- first try to update the key
	UPDATE goiardi.environments SET description = m_description, default_attr = m_default_attr, override_attr = m_override_attr, cookbook_vers = m_cookbook_vers, updated_at = NOW() WHERE name = m_name;
	IF found THEN
		RETURN;
	END IF;
        -- not there, so try to insert the key
        -- if someone else inserts the same key concurrently,
        -- we could get a unique-key failure
        BEGIN
	    INSERT INTO goiardi.environments (name, description, default_attr, override_attr, cookbook_vers, created_at, updated_at) VALUES (m_name, m_description, m_default_attr, m_override_attr, m_cookbook_vers, NOW(), NOW());
            RETURN;
        EXCEPTION WHEN unique_violation THEN
            -- Do nothing, and loop to try the UPDATE again.
        END;
    END LOOP;
END;
$$;


--
-- Name: merge_nodes(text, text, json, json, json, json, json); Type: FUNCTION; Schema: goiardi; Owner: -
--

CREATE FUNCTION merge_nodes(m_name text, m_chef_environment text, m_run_list json, m_automatic_attr json, m_normal_attr json, m_default_attr json, m_override_attr json) RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN
    LOOP
        -- first try to update the key
	UPDATE goiardi.nodes SET chef_environment = m_chef_environment, run_list = m_run_list, automatic_attr = m_automatic_attr, normal_attr = m_normal_attr, default_attr = m_default_attr, override_attr = m_override_attr, updated_at = NOW() WHERE name = m_name;
	IF found THEN
	    RETURN;
	END IF;
        -- not there, so try to insert the key
        -- if someone else inserts the same key concurrently,
        -- we could get a unique-key failure
        BEGIN
	    INSERT INTO goiardi.nodes (name, chef_environment, run_list, automatic_attr, normal_attr, default_attr, override_attr, created_at, updated_at) VALUES (m_name, m_chef_environment, m_run_list, m_automatic_attr, m_normal_attr, m_default_attr, m_override_attr, NOW(), NOW());
            RETURN;
        EXCEPTION WHEN unique_violation THEN
            -- Do nothing, and loop to try the UPDATE again.
        END;
    END LOOP;
END;
$$;


--
-- Name: merge_reports(uuid, text, timestamp with time zone, timestamp with time zone, integer, report_status, text, json, json); Type: FUNCTION; Schema: goiardi; Owner: -
--

CREATE FUNCTION merge_reports(m_run_id uuid, m_node_name text, m_start_time timestamp with time zone, m_end_time timestamp with time zone, m_total_res_count integer, m_status report_status, m_run_list text, m_resources json, m_data json) RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN
    LOOP
        -- first try to update the key
	UPDATE goiardi.reports SET start_time = m_start_time, end_time = m_end_time, total_res_count = m_total_res_count, status = m_status, run_list = m_run_list, resources = m_resources, data = m_data, updated_at = NOW() WHERE run_id = m_run_id;
	IF found THEN
	    RETURN;
	END IF;
        -- not there, so try to insert the key
        -- if someone else inserts the same key concurrently,
        -- we could get a unique-key failure
        BEGIN
	    INSERT INTO goiardi.reports (run_id, node_name, start_time, end_time, total_res_count, status, run_list, resources, data, created_at, updated_at) VALUES (m_run_id, m_node_name, m_start_time, m_end_time, m_total_res_count, m_status, m_run_list, m_resources, m_data, NOW(), NOW());
            RETURN;
        EXCEPTION WHEN unique_violation THEN
            -- Do nothing, and loop to try the UPDATE again.
        END;
    END LOOP;
END;
$$;


--
-- Name: merge_roles(text, text, json, json, json, json); Type: FUNCTION; Schema: goiardi; Owner: -
--

CREATE FUNCTION merge_roles(m_name text, m_description text, m_run_list json, m_env_run_lists json, m_default_attr json, m_override_attr json) RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN
    LOOP
        -- first try to update the key
	UPDATE goiardi.roles SET description = m_description, run_list = m_run_list, env_run_lists = m_env_run_lists, default_attr = m_default_attr, override_attr = m_override_attr, updated_at = NOW() WHERE name = m_name;
	IF found THEN
	    RETURN;
	END IF;
        -- not there, so try to insert the key
        -- if someone else inserts the same key concurrently,
        -- we could get a unique-key failure
        BEGIN
	    INSERT INTO goiardi.roles (name, description, run_list, env_run_lists, default_attr, override_attr, created_at, updated_at) VALUES (m_name, m_description, m_run_list, m_env_run_lists, m_default_attr, m_override_attr, NOW(), NOW());
            RETURN;
        EXCEPTION WHEN unique_violation THEN
            -- Do nothing, and loop to try the UPDATE again.
        END;
    END LOOP;
END;
$$;


--
-- Name: merge_sandboxes(character varying, timestamp with time zone, json, boolean); Type: FUNCTION; Schema: goiardi; Owner: -
--

CREATE FUNCTION merge_sandboxes(m_sbox_id character varying, m_creation_time timestamp with time zone, m_checksums json, m_completed boolean) RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN
    LOOP
        -- first try to update the key
	UPDATE goiardi.sandboxes SET checksums = m_checksums, completed = m_completed WHERE sbox_id = m_sbox_id;
	IF found THEN
	    RETURN;
	END IF;
        -- not there, so try to insert the key
        -- if someone else inserts the same key concurrently,
        -- we could get a unique-key failure
        BEGIN
	    INSERT INTO goiardi.sandboxes (sbox_id, creation_time, checksums, completed) VALUES (m_sbox_id, m_creation_time, m_checksums, m_completed);
            RETURN;
        EXCEPTION WHEN unique_violation THEN
            -- Do nothing, and loop to try the UPDATE again.
        END;
    END LOOP;
END;
$$;


--
-- Name: merge_shovey_runs(uuid, text, text, timestamp with time zone, timestamp with time zone, text, integer); Type: FUNCTION; Schema: goiardi; Owner: -
--

CREATE FUNCTION merge_shovey_runs(m_shovey_run_id uuid, m_node_name text, m_status text, m_ack_time timestamp with time zone, m_end_time timestamp with time zone, m_error text, m_exit_status integer) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
    m_shovey_id bigint;
BEGIN
    LOOP
	UPDATE goiardi.shovey_runs SET status = m_status, ack_time = NULLIF(m_ack_time, '0001-01-01 00:00:00 +0000'), end_time = NULLIF(m_end_time, '0001-01-01 00:00:00 +0000'), error = m_error, exit_status = cast(m_exit_status as smallint) WHERE shovey_uuid = m_shovey_run_id AND node_name = m_node_name;
	IF found THEN
	    RETURN;
	END IF;
	BEGIN
	    SELECT id INTO m_shovey_id FROM goiardi.shoveys WHERE run_id = m_shovey_run_id;
	    INSERT INTO goiardi.shovey_runs (shovey_uuid, shovey_id, node_name, status, ack_time, end_time, error, exit_status) VALUES (m_shovey_run_id, m_shovey_id, m_node_name, m_status, NULLIF(m_ack_time, '0001-01-01 00:00:00 +0000'),NULLIF(m_end_time, '0001-01-01 00:00:00 +0000'), m_error, cast(m_exit_status as smallint));
	EXCEPTION WHEN unique_violation THEN
	    -- meh.
	END;
    END LOOP;
END;
$$;


--
-- Name: merge_shoveys(uuid, text, text, bigint, character varying); Type: FUNCTION; Schema: goiardi; Owner: -
--

CREATE FUNCTION merge_shoveys(m_run_id uuid, m_command text, m_status text, m_timeout bigint, m_quorum character varying) RETURNS void
    LANGUAGE plpgsql
    AS $$
BEGIN
    LOOP
	UPDATE goiardi.shoveys SET status = m_status, updated_at = NOW() WHERE run_id = m_run_id;
        IF found THEN
	    RETURN;
    	END IF;
    	BEGIN
	    INSERT INTO goiardi.shoveys (run_id, command, status, timeout, quorum, created_at, updated_at) VALUES (m_run_id, m_command, m_status, m_timeout, m_quorum, NOW(), NOW());
            RETURN;
        EXCEPTION WHEN unique_violation THEN
            -- moo.
    	END;
    END LOOP;
END;
$$;


--
-- Name: merge_users(text, text, text, boolean, text, character varying, bytea, bigint); Type: FUNCTION; Schema: goiardi; Owner: -
--

CREATE FUNCTION merge_users(m_name text, m_displayname text, m_email text, m_admin boolean, m_public_key text, m_passwd character varying, m_salt bytea, m_organization_id bigint) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
    c_id bigint;
    c_name text;
BEGIN
    SELECT id, name INTO c_id, c_name FROM goiardi.clients WHERE name = m_name AND organization_id = m_organization_id;
    IF FOUND THEN
        RAISE EXCEPTION 'a client with id % named % was found that would conflict with this client', c_id, c_name;
    END IF;
    IF m_email = '' THEN
        m_email := NULL;
    END IF;
    LOOP
        -- first try to update the key
        UPDATE goiardi.users SET name = m_name, displayname = m_displayname, email = m_email, admin = m_admin, public_key = m_public_key, passwd = m_passwd, salt = m_salt, updated_at = NOW() WHERE name = m_name;
        IF found THEN
            RETURN;
        END IF;
        -- not there, so try to insert the key
        -- if someone else inserts the same key concurrently,
        -- we could get a unique-key failure
        BEGIN
            INSERT INTO goiardi.users (name, displayname, email, admin, public_key, passwd, salt, created_at, updated_at) VALUES (m_name, m_displayname, m_email, m_admin, m_public_key, m_passwd, m_salt, NOW(), NOW());
            RETURN;
        END;
    END LOOP;
END;
$$;


--
-- Name: rename_client(text, text); Type: FUNCTION; Schema: goiardi; Owner: -
--

CREATE FUNCTION rename_client(old_name text, new_name text) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
	u_id bigint;
	u_name text;
BEGIN
	SELECT id, name INTO u_id, u_name FROM goiardi.users WHERE name = new_name;
	IF FOUND THEN
		RAISE EXCEPTION 'a user with id % named % was found that would conflict with this client', u_id, u_name;
	END IF;
	BEGIN
		UPDATE goiardi.clients SET name = new_name WHERE name = old_name;
	EXCEPTION WHEN unique_violation THEN
		RAISE EXCEPTION 'Client % already exists, cannot rename %', old_name, new_name;
	END;
END;
$$;


--
-- Name: rename_user(text, text, integer); Type: FUNCTION; Schema: goiardi; Owner: -
--

CREATE FUNCTION rename_user(old_name text, new_name text, m_organization_id integer) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
	c_id bigint;
	c_name text;
BEGIN
	SELECT id, name INTO c_id, c_name FROM goiardi.clients WHERE name = new_name AND organization_id = m_organization_id;
	IF FOUND THEN
		RAISE EXCEPTION 'a client with id % named % was found that would conflict with this user', c_id, c_name;
	END IF;
	BEGIN
		UPDATE goiardi.users SET name = new_name WHERE name = old_name;
	EXCEPTION WHEN unique_violation THEN
		RAISE EXCEPTION 'User % already exists, cannot rename %', old_name, new_name;
	END;
END;
$$;


SET default_tablespace = '';

SET default_with_oids = false;

--
-- Name: clients; Type: TABLE; Schema: goiardi; Owner: -; Tablespace: 
--

CREATE TABLE clients (
    id bigint NOT NULL,
    name text NOT NULL,
    nodename text,
    validator boolean,
    admin boolean,
    organization_id bigint DEFAULT 1 NOT NULL,
    public_key text,
    certificate text,
    created_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone NOT NULL
);


--
-- Name: clients_id_seq; Type: SEQUENCE; Schema: goiardi; Owner: -
--

CREATE SEQUENCE clients_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: clients_id_seq; Type: SEQUENCE OWNED BY; Schema: goiardi; Owner: -
--

ALTER SEQUENCE clients_id_seq OWNED BY clients.id;


--
-- Name: cookbook_versions; Type: TABLE; Schema: goiardi; Owner: -; Tablespace: 
--

CREATE TABLE cookbook_versions (
    id bigint NOT NULL,
    cookbook_id bigint NOT NULL,
    major_ver bigint NOT NULL,
    minor_ver bigint NOT NULL,
    patch_ver bigint DEFAULT 0 NOT NULL,
    frozen boolean,
    metadata json,
    definitions json,
    libraries json,
    attributes json,
    recipes json,
    providers json,
    resources json,
    templates json,
    root_files json,
    files json,
    created_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone NOT NULL
);


--
-- Name: cookbook_versions_id_seq; Type: SEQUENCE; Schema: goiardi; Owner: -
--

CREATE SEQUENCE cookbook_versions_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: cookbook_versions_id_seq; Type: SEQUENCE OWNED BY; Schema: goiardi; Owner: -
--

ALTER SEQUENCE cookbook_versions_id_seq OWNED BY cookbook_versions.id;


--
-- Name: cookbooks; Type: TABLE; Schema: goiardi; Owner: -; Tablespace: 
--

CREATE TABLE cookbooks (
    id bigint NOT NULL,
    name text NOT NULL,
    organization_id bigint DEFAULT 1 NOT NULL,
    created_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone NOT NULL
);


--
-- Name: cookbooks_id_seq; Type: SEQUENCE; Schema: goiardi; Owner: -
--

CREATE SEQUENCE cookbooks_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: cookbooks_id_seq; Type: SEQUENCE OWNED BY; Schema: goiardi; Owner: -
--

ALTER SEQUENCE cookbooks_id_seq OWNED BY cookbooks.id;


--
-- Name: data_bag_items; Type: TABLE; Schema: goiardi; Owner: -; Tablespace: 
--

CREATE TABLE data_bag_items (
    id bigint NOT NULL,
    name text NOT NULL,
    orig_name text NOT NULL,
    data_bag_id bigint NOT NULL,
    raw_data json,
    created_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone NOT NULL
);


--
-- Name: data_bag_items_id_seq; Type: SEQUENCE; Schema: goiardi; Owner: -
--

CREATE SEQUENCE data_bag_items_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: data_bag_items_id_seq; Type: SEQUENCE OWNED BY; Schema: goiardi; Owner: -
--

ALTER SEQUENCE data_bag_items_id_seq OWNED BY data_bag_items.id;


--
-- Name: data_bags; Type: TABLE; Schema: goiardi; Owner: -; Tablespace: 
--

CREATE TABLE data_bags (
    id bigint NOT NULL,
    name text NOT NULL,
    organization_id bigint DEFAULT 1 NOT NULL,
    created_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone NOT NULL
);


--
-- Name: data_bags_id_seq; Type: SEQUENCE; Schema: goiardi; Owner: -
--

CREATE SEQUENCE data_bags_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: data_bags_id_seq; Type: SEQUENCE OWNED BY; Schema: goiardi; Owner: -
--

ALTER SEQUENCE data_bags_id_seq OWNED BY data_bags.id;


--
-- Name: environments; Type: TABLE; Schema: goiardi; Owner: -; Tablespace: 
--

CREATE TABLE environments (
    id bigint NOT NULL,
    name text,
    organization_id bigint DEFAULT 1 NOT NULL,
    description text,
    default_attr json,
    override_attr json,
    cookbook_vers json,
    created_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone NOT NULL
);


--
-- Name: environments_id_seq; Type: SEQUENCE; Schema: goiardi; Owner: -
--

CREATE SEQUENCE environments_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: environments_id_seq; Type: SEQUENCE OWNED BY; Schema: goiardi; Owner: -
--

ALTER SEQUENCE environments_id_seq OWNED BY environments.id;


--
-- Name: file_checksums; Type: TABLE; Schema: goiardi; Owner: -; Tablespace: 
--

CREATE TABLE file_checksums (
    id bigint NOT NULL,
    organization_id bigint DEFAULT 1 NOT NULL,
    checksum character varying(32)
);


--
-- Name: file_checksums_id_seq; Type: SEQUENCE; Schema: goiardi; Owner: -
--

CREATE SEQUENCE file_checksums_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: file_checksums_id_seq; Type: SEQUENCE OWNED BY; Schema: goiardi; Owner: -
--

ALTER SEQUENCE file_checksums_id_seq OWNED BY file_checksums.id;


--
-- Name: joined_cookbook_version; Type: VIEW; Schema: goiardi; Owner: -
--

CREATE VIEW joined_cookbook_version AS
 SELECT v.major_ver,
    v.minor_ver,
    v.patch_ver,
    ((((v.major_ver || '.'::text) || v.minor_ver) || '.'::text) || v.patch_ver) AS version,
    v.id,
    v.metadata,
    v.recipes,
    c.organization_id,
    c.name
   FROM (cookbooks c
   JOIN cookbook_versions v ON ((c.id = v.cookbook_id)));


--
-- Name: log_infos; Type: TABLE; Schema: goiardi; Owner: -; Tablespace: 
--

CREATE TABLE log_infos (
    id bigint NOT NULL,
    actor_id bigint DEFAULT 0 NOT NULL,
    actor_info text,
    actor_type log_actor NOT NULL,
    organization_id bigint DEFAULT 1::bigint NOT NULL,
    "time" timestamp with time zone DEFAULT now(),
    action log_action NOT NULL,
    object_type text NOT NULL,
    object_name text NOT NULL,
    extended_info text
);
ALTER TABLE ONLY log_infos ALTER COLUMN extended_info SET STORAGE EXTERNAL;


--
-- Name: log_infos_id_seq; Type: SEQUENCE; Schema: goiardi; Owner: -
--

CREATE SEQUENCE log_infos_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: log_infos_id_seq; Type: SEQUENCE OWNED BY; Schema: goiardi; Owner: -
--

ALTER SEQUENCE log_infos_id_seq OWNED BY log_infos.id;


--
-- Name: node_statuses; Type: TABLE; Schema: goiardi; Owner: -; Tablespace: 
--

CREATE TABLE node_statuses (
    id bigint NOT NULL,
    node_id bigint NOT NULL,
    status status_node DEFAULT 'new'::status_node NOT NULL,
    updated_at timestamp with time zone NOT NULL
);


--
-- Name: nodes; Type: TABLE; Schema: goiardi; Owner: -; Tablespace: 
--

CREATE TABLE nodes (
    id bigint NOT NULL,
    name text NOT NULL,
    organization_id bigint DEFAULT 1 NOT NULL,
    chef_environment text DEFAULT '_default'::text NOT NULL,
    run_list json,
    automatic_attr json,
    normal_attr json,
    default_attr json,
    override_attr json,
    created_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone NOT NULL,
    is_down boolean DEFAULT false
);


--
-- Name: node_latest_statuses; Type: VIEW; Schema: goiardi; Owner: -
--

CREATE VIEW node_latest_statuses AS
 SELECT DISTINCT ON (n.id) n.id,
    n.name,
    n.chef_environment,
    n.run_list,
    n.automatic_attr,
    n.normal_attr,
    n.default_attr,
    n.override_attr,
    n.is_down,
    ns.status,
    ns.updated_at
   FROM (nodes n
   JOIN node_statuses ns ON ((n.id = ns.node_id)))
  ORDER BY n.id, ns.updated_at DESC;


--
-- Name: node_statuses_id_seq; Type: SEQUENCE; Schema: goiardi; Owner: -
--

CREATE SEQUENCE node_statuses_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: node_statuses_id_seq; Type: SEQUENCE OWNED BY; Schema: goiardi; Owner: -
--

ALTER SEQUENCE node_statuses_id_seq OWNED BY node_statuses.id;


--
-- Name: nodes_id_seq; Type: SEQUENCE; Schema: goiardi; Owner: -
--

CREATE SEQUENCE nodes_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: nodes_id_seq; Type: SEQUENCE OWNED BY; Schema: goiardi; Owner: -
--

ALTER SEQUENCE nodes_id_seq OWNED BY nodes.id;


--
-- Name: organizations; Type: TABLE; Schema: goiardi; Owner: -; Tablespace: 
--

CREATE TABLE organizations (
    id bigint NOT NULL,
    name text NOT NULL,
    description text,
    created_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone NOT NULL
);


--
-- Name: organizations_id_seq; Type: SEQUENCE; Schema: goiardi; Owner: -
--

CREATE SEQUENCE organizations_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: organizations_id_seq; Type: SEQUENCE OWNED BY; Schema: goiardi; Owner: -
--

ALTER SEQUENCE organizations_id_seq OWNED BY organizations.id;


--
-- Name: reports; Type: TABLE; Schema: goiardi; Owner: -; Tablespace: 
--

CREATE TABLE reports (
    id bigint NOT NULL,
    run_id uuid NOT NULL,
    node_name character varying(255),
    organization_id bigint DEFAULT 1 NOT NULL,
    start_time timestamp with time zone,
    end_time timestamp with time zone,
    total_res_count integer DEFAULT 0,
    status report_status,
    run_list text,
    resources json,
    data json,
    created_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone NOT NULL
);
ALTER TABLE ONLY reports ALTER COLUMN run_list SET STORAGE EXTERNAL;


--
-- Name: reports_id_seq; Type: SEQUENCE; Schema: goiardi; Owner: -
--

CREATE SEQUENCE reports_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: reports_id_seq; Type: SEQUENCE OWNED BY; Schema: goiardi; Owner: -
--

ALTER SEQUENCE reports_id_seq OWNED BY reports.id;


--
-- Name: roles; Type: TABLE; Schema: goiardi; Owner: -; Tablespace: 
--

CREATE TABLE roles (
    id bigint NOT NULL,
    name text NOT NULL,
    organization_id bigint DEFAULT 1 NOT NULL,
    description text,
    run_list json,
    env_run_lists json,
    default_attr json,
    override_attr json,
    created_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone NOT NULL
);


--
-- Name: roles_id_seq; Type: SEQUENCE; Schema: goiardi; Owner: -
--

CREATE SEQUENCE roles_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: roles_id_seq; Type: SEQUENCE OWNED BY; Schema: goiardi; Owner: -
--

ALTER SEQUENCE roles_id_seq OWNED BY roles.id;


--
-- Name: sandboxes; Type: TABLE; Schema: goiardi; Owner: -; Tablespace: 
--

CREATE TABLE sandboxes (
    id bigint NOT NULL,
    sbox_id character varying(32) NOT NULL,
    organization_id bigint DEFAULT 1 NOT NULL,
    creation_time timestamp with time zone NOT NULL,
    checksums json,
    completed boolean
);


--
-- Name: sandboxes_id_seq; Type: SEQUENCE; Schema: goiardi; Owner: -
--

CREATE SEQUENCE sandboxes_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: sandboxes_id_seq; Type: SEQUENCE OWNED BY; Schema: goiardi; Owner: -
--

ALTER SEQUENCE sandboxes_id_seq OWNED BY sandboxes.id;


--
-- Name: search_collections; Type: TABLE; Schema: goiardi; Owner: -; Tablespace: 
--

CREATE TABLE search_collections (
    id bigint NOT NULL,
    organization_id bigint DEFAULT 1 NOT NULL,
    name text
);


--
-- Name: search_collections_id_seq; Type: SEQUENCE; Schema: goiardi; Owner: -
--

CREATE SEQUENCE search_collections_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: search_collections_id_seq; Type: SEQUENCE OWNED BY; Schema: goiardi; Owner: -
--

ALTER SEQUENCE search_collections_id_seq OWNED BY search_collections.id;


--
-- Name: search_items; Type: TABLE; Schema: goiardi; Owner: -; Tablespace: 
--

CREATE TABLE search_items (
    id bigint NOT NULL,
    organization_id bigint DEFAULT 1 NOT NULL,
    search_collection_id bigint NOT NULL,
    item_name text,
    value text,
    path ltree
);


--
-- Name: search_items_id_seq; Type: SEQUENCE; Schema: goiardi; Owner: -
--

CREATE SEQUENCE search_items_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: search_items_id_seq; Type: SEQUENCE OWNED BY; Schema: goiardi; Owner: -
--

ALTER SEQUENCE search_items_id_seq OWNED BY search_items.id;


--
-- Name: shovey_run_streams; Type: TABLE; Schema: goiardi; Owner: -; Tablespace: 
--

CREATE TABLE shovey_run_streams (
    id bigint NOT NULL,
    shovey_run_id bigint NOT NULL,
    seq integer NOT NULL,
    output_type shovey_output,
    output text,
    is_last boolean,
    created_at timestamp with time zone NOT NULL
);


--
-- Name: shovey_run_streams_id_seq; Type: SEQUENCE; Schema: goiardi; Owner: -
--

CREATE SEQUENCE shovey_run_streams_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: shovey_run_streams_id_seq; Type: SEQUENCE OWNED BY; Schema: goiardi; Owner: -
--

ALTER SEQUENCE shovey_run_streams_id_seq OWNED BY shovey_run_streams.id;


--
-- Name: shovey_runs; Type: TABLE; Schema: goiardi; Owner: -; Tablespace: 
--

CREATE TABLE shovey_runs (
    id bigint NOT NULL,
    shovey_uuid uuid NOT NULL,
    shovey_id bigint NOT NULL,
    node_name text,
    status text,
    ack_time timestamp with time zone,
    end_time timestamp with time zone,
    error text,
    exit_status smallint
);


--
-- Name: shovey_runs_id_seq; Type: SEQUENCE; Schema: goiardi; Owner: -
--

CREATE SEQUENCE shovey_runs_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: shovey_runs_id_seq; Type: SEQUENCE OWNED BY; Schema: goiardi; Owner: -
--

ALTER SEQUENCE shovey_runs_id_seq OWNED BY shovey_runs.id;


--
-- Name: shoveys; Type: TABLE; Schema: goiardi; Owner: -; Tablespace: 
--

CREATE TABLE shoveys (
    id bigint NOT NULL,
    run_id uuid NOT NULL,
    command text,
    status text,
    timeout bigint DEFAULT 300,
    quorum character varying(25) DEFAULT '100%'::character varying,
    created_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone NOT NULL,
    organization_id bigint DEFAULT 1 NOT NULL
);


--
-- Name: shoveys_id_seq; Type: SEQUENCE; Schema: goiardi; Owner: -
--

CREATE SEQUENCE shoveys_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: shoveys_id_seq; Type: SEQUENCE OWNED BY; Schema: goiardi; Owner: -
--

ALTER SEQUENCE shoveys_id_seq OWNED BY shoveys.id;


--
-- Name: users; Type: TABLE; Schema: goiardi; Owner: -; Tablespace: 
--

CREATE TABLE users (
    id bigint NOT NULL,
    name text NOT NULL,
    displayname text,
    email text,
    admin boolean,
    public_key text,
    passwd character varying(128),
    salt bytea,
    created_at timestamp with time zone NOT NULL,
    updated_at timestamp with time zone NOT NULL
);


--
-- Name: users_id_seq; Type: SEQUENCE; Schema: goiardi; Owner: -
--

CREATE SEQUENCE users_id_seq
    START WITH 1
    INCREMENT BY 1
    NO MINVALUE
    NO MAXVALUE
    CACHE 1;


--
-- Name: users_id_seq; Type: SEQUENCE OWNED BY; Schema: goiardi; Owner: -
--

ALTER SEQUENCE users_id_seq OWNED BY users.id;


SET search_path = sqitch, pg_catalog;

--
-- Name: changes; Type: TABLE; Schema: sqitch; Owner: -; Tablespace: 
--

CREATE TABLE changes (
    change_id text NOT NULL,
    change text NOT NULL,
    project text NOT NULL,
    note text DEFAULT ''::text NOT NULL,
    committed_at timestamp with time zone DEFAULT clock_timestamp() NOT NULL,
    committer_name text NOT NULL,
    committer_email text NOT NULL,
    planned_at timestamp with time zone NOT NULL,
    planner_name text NOT NULL,
    planner_email text NOT NULL
);


--
-- Name: TABLE changes; Type: COMMENT; Schema: sqitch; Owner: -
--

COMMENT ON TABLE changes IS 'Tracks the changes currently deployed to the database.';


--
-- Name: COLUMN changes.change_id; Type: COMMENT; Schema: sqitch; Owner: -
--

COMMENT ON COLUMN changes.change_id IS 'Change primary key.';


--
-- Name: COLUMN changes.change; Type: COMMENT; Schema: sqitch; Owner: -
--

COMMENT ON COLUMN changes.change IS 'Name of a deployed change.';


--
-- Name: COLUMN changes.project; Type: COMMENT; Schema: sqitch; Owner: -
--

COMMENT ON COLUMN changes.project IS 'Name of the Sqitch project to which the change belongs.';


--
-- Name: COLUMN changes.note; Type: COMMENT; Schema: sqitch; Owner: -
--

COMMENT ON COLUMN changes.note IS 'Description of the change.';


--
-- Name: COLUMN changes.committed_at; Type: COMMENT; Schema: sqitch; Owner: -
--

COMMENT ON COLUMN changes.committed_at IS 'Date the change was deployed.';


--
-- Name: COLUMN changes.committer_name; Type: COMMENT; Schema: sqitch; Owner: -
--

COMMENT ON COLUMN changes.committer_name IS 'Name of the user who deployed the change.';


--
-- Name: COLUMN changes.committer_email; Type: COMMENT; Schema: sqitch; Owner: -
--

COMMENT ON COLUMN changes.committer_email IS 'Email address of the user who deployed the change.';


--
-- Name: COLUMN changes.planned_at; Type: COMMENT; Schema: sqitch; Owner: -
--

COMMENT ON COLUMN changes.planned_at IS 'Date the change was added to the plan.';


--
-- Name: COLUMN changes.planner_name; Type: COMMENT; Schema: sqitch; Owner: -
--

COMMENT ON COLUMN changes.planner_name IS 'Name of the user who planed the change.';


--
-- Name: COLUMN changes.planner_email; Type: COMMENT; Schema: sqitch; Owner: -
--

COMMENT ON COLUMN changes.planner_email IS 'Email address of the user who planned the change.';


--
-- Name: dependencies; Type: TABLE; Schema: sqitch; Owner: -; Tablespace: 
--

CREATE TABLE dependencies (
    change_id text NOT NULL,
    type text NOT NULL,
    dependency text NOT NULL,
    dependency_id text,
    CONSTRAINT dependencies_check CHECK ((((type = 'require'::text) AND (dependency_id IS NOT NULL)) OR ((type = 'conflict'::text) AND (dependency_id IS NULL))))
);


--
-- Name: TABLE dependencies; Type: COMMENT; Schema: sqitch; Owner: -
--

COMMENT ON TABLE dependencies IS 'Tracks the currently satisfied dependencies.';


--
-- Name: COLUMN dependencies.change_id; Type: COMMENT; Schema: sqitch; Owner: -
--

COMMENT ON COLUMN dependencies.change_id IS 'ID of the depending change.';


--
-- Name: COLUMN dependencies.type; Type: COMMENT; Schema: sqitch; Owner: -
--

COMMENT ON COLUMN dependencies.type IS 'Type of dependency.';


--
-- Name: COLUMN dependencies.dependency; Type: COMMENT; Schema: sqitch; Owner: -
--

COMMENT ON COLUMN dependencies.dependency IS 'Dependency name.';


--
-- Name: COLUMN dependencies.dependency_id; Type: COMMENT; Schema: sqitch; Owner: -
--

COMMENT ON COLUMN dependencies.dependency_id IS 'Change ID the dependency resolves to.';


--
-- Name: events; Type: TABLE; Schema: sqitch; Owner: -; Tablespace: 
--

CREATE TABLE events (
    event text NOT NULL,
    change_id text NOT NULL,
    change text NOT NULL,
    project text NOT NULL,
    note text DEFAULT ''::text NOT NULL,
    requires text[] DEFAULT '{}'::text[] NOT NULL,
    conflicts text[] DEFAULT '{}'::text[] NOT NULL,
    tags text[] DEFAULT '{}'::text[] NOT NULL,
    committed_at timestamp with time zone DEFAULT clock_timestamp() NOT NULL,
    committer_name text NOT NULL,
    committer_email text NOT NULL,
    planned_at timestamp with time zone NOT NULL,
    planner_name text NOT NULL,
    planner_email text NOT NULL,
    CONSTRAINT events_event_check CHECK ((event = ANY (ARRAY['deploy'::text, 'revert'::text, 'fail'::text])))
);


--
-- Name: TABLE events; Type: COMMENT; Schema: sqitch; Owner: -
--

COMMENT ON TABLE events IS 'Contains full history of all deployment events.';


--
-- Name: COLUMN events.event; Type: COMMENT; Schema: sqitch; Owner: -
--

COMMENT ON COLUMN events.event IS 'Type of event.';


--
-- Name: COLUMN events.change_id; Type: COMMENT; Schema: sqitch; Owner: -
--

COMMENT ON COLUMN events.change_id IS 'Change ID.';


--
-- Name: COLUMN events.change; Type: COMMENT; Schema: sqitch; Owner: -
--

COMMENT ON COLUMN events.change IS 'Change name.';


--
-- Name: COLUMN events.project; Type: COMMENT; Schema: sqitch; Owner: -
--

COMMENT ON COLUMN events.project IS 'Name of the Sqitch project to which the change belongs.';


--
-- Name: COLUMN events.note; Type: COMMENT; Schema: sqitch; Owner: -
--

COMMENT ON COLUMN events.note IS 'Description of the change.';


--
-- Name: COLUMN events.requires; Type: COMMENT; Schema: sqitch; Owner: -
--

COMMENT ON COLUMN events.requires IS 'Array of the names of required changes.';


--
-- Name: COLUMN events.conflicts; Type: COMMENT; Schema: sqitch; Owner: -
--

COMMENT ON COLUMN events.conflicts IS 'Array of the names of conflicting changes.';


--
-- Name: COLUMN events.tags; Type: COMMENT; Schema: sqitch; Owner: -
--

COMMENT ON COLUMN events.tags IS 'Tags associated with the change.';


--
-- Name: COLUMN events.committed_at; Type: COMMENT; Schema: sqitch; Owner: -
--

COMMENT ON COLUMN events.committed_at IS 'Date the event was committed.';


--
-- Name: COLUMN events.committer_name; Type: COMMENT; Schema: sqitch; Owner: -
--

COMMENT ON COLUMN events.committer_name IS 'Name of the user who committed the event.';


--
-- Name: COLUMN events.committer_email; Type: COMMENT; Schema: sqitch; Owner: -
--

COMMENT ON COLUMN events.committer_email IS 'Email address of the user who committed the event.';


--
-- Name: COLUMN events.planned_at; Type: COMMENT; Schema: sqitch; Owner: -
--

COMMENT ON COLUMN events.planned_at IS 'Date the event was added to the plan.';


--
-- Name: COLUMN events.planner_name; Type: COMMENT; Schema: sqitch; Owner: -
--

COMMENT ON COLUMN events.planner_name IS 'Name of the user who planed the change.';


--
-- Name: COLUMN events.planner_email; Type: COMMENT; Schema: sqitch; Owner: -
--

COMMENT ON COLUMN events.planner_email IS 'Email address of the user who plan planned the change.';


--
-- Name: projects; Type: TABLE; Schema: sqitch; Owner: -; Tablespace: 
--

CREATE TABLE projects (
    project text NOT NULL,
    uri text,
    created_at timestamp with time zone DEFAULT clock_timestamp() NOT NULL,
    creator_name text NOT NULL,
    creator_email text NOT NULL
);


--
-- Name: TABLE projects; Type: COMMENT; Schema: sqitch; Owner: -
--

COMMENT ON TABLE projects IS 'Sqitch projects deployed to this database.';


--
-- Name: COLUMN projects.project; Type: COMMENT; Schema: sqitch; Owner: -
--

COMMENT ON COLUMN projects.project IS 'Unique Name of a project.';


--
-- Name: COLUMN projects.uri; Type: COMMENT; Schema: sqitch; Owner: -
--

COMMENT ON COLUMN projects.uri IS 'Optional project URI';


--
-- Name: COLUMN projects.created_at; Type: COMMENT; Schema: sqitch; Owner: -
--

COMMENT ON COLUMN projects.created_at IS 'Date the project was added to the database.';


--
-- Name: COLUMN projects.creator_name; Type: COMMENT; Schema: sqitch; Owner: -
--

COMMENT ON COLUMN projects.creator_name IS 'Name of the user who added the project.';


--
-- Name: COLUMN projects.creator_email; Type: COMMENT; Schema: sqitch; Owner: -
--

COMMENT ON COLUMN projects.creator_email IS 'Email address of the user who added the project.';


--
-- Name: tags; Type: TABLE; Schema: sqitch; Owner: -; Tablespace: 
--

CREATE TABLE tags (
    tag_id text NOT NULL,
    tag text NOT NULL,
    project text NOT NULL,
    change_id text NOT NULL,
    note text DEFAULT ''::text NOT NULL,
    committed_at timestamp with time zone DEFAULT clock_timestamp() NOT NULL,
    committer_name text NOT NULL,
    committer_email text NOT NULL,
    planned_at timestamp with time zone NOT NULL,
    planner_name text NOT NULL,
    planner_email text NOT NULL
);


--
-- Name: TABLE tags; Type: COMMENT; Schema: sqitch; Owner: -
--

COMMENT ON TABLE tags IS 'Tracks the tags currently applied to the database.';


--
-- Name: COLUMN tags.tag_id; Type: COMMENT; Schema: sqitch; Owner: -
--

COMMENT ON COLUMN tags.tag_id IS 'Tag primary key.';


--
-- Name: COLUMN tags.tag; Type: COMMENT; Schema: sqitch; Owner: -
--

COMMENT ON COLUMN tags.tag IS 'Project-unique tag name.';


--
-- Name: COLUMN tags.project; Type: COMMENT; Schema: sqitch; Owner: -
--

COMMENT ON COLUMN tags.project IS 'Name of the Sqitch project to which the tag belongs.';


--
-- Name: COLUMN tags.change_id; Type: COMMENT; Schema: sqitch; Owner: -
--

COMMENT ON COLUMN tags.change_id IS 'ID of last change deployed before the tag was applied.';


--
-- Name: COLUMN tags.note; Type: COMMENT; Schema: sqitch; Owner: -
--

COMMENT ON COLUMN tags.note IS 'Description of the tag.';


--
-- Name: COLUMN tags.committed_at; Type: COMMENT; Schema: sqitch; Owner: -
--

COMMENT ON COLUMN tags.committed_at IS 'Date the tag was applied to the database.';


--
-- Name: COLUMN tags.committer_name; Type: COMMENT; Schema: sqitch; Owner: -
--

COMMENT ON COLUMN tags.committer_name IS 'Name of the user who applied the tag.';


--
-- Name: COLUMN tags.committer_email; Type: COMMENT; Schema: sqitch; Owner: -
--

COMMENT ON COLUMN tags.committer_email IS 'Email address of the user who applied the tag.';


--
-- Name: COLUMN tags.planned_at; Type: COMMENT; Schema: sqitch; Owner: -
--

COMMENT ON COLUMN tags.planned_at IS 'Date the tag was added to the plan.';


--
-- Name: COLUMN tags.planner_name; Type: COMMENT; Schema: sqitch; Owner: -
--

COMMENT ON COLUMN tags.planner_name IS 'Name of the user who planed the tag.';


--
-- Name: COLUMN tags.planner_email; Type: COMMENT; Schema: sqitch; Owner: -
--

COMMENT ON COLUMN tags.planner_email IS 'Email address of the user who planned the tag.';


SET search_path = goiardi, pg_catalog;

--
-- Name: id; Type: DEFAULT; Schema: goiardi; Owner: -
--

ALTER TABLE ONLY clients ALTER COLUMN id SET DEFAULT nextval('clients_id_seq'::regclass);


--
-- Name: id; Type: DEFAULT; Schema: goiardi; Owner: -
--

ALTER TABLE ONLY cookbook_versions ALTER COLUMN id SET DEFAULT nextval('cookbook_versions_id_seq'::regclass);


--
-- Name: id; Type: DEFAULT; Schema: goiardi; Owner: -
--

ALTER TABLE ONLY cookbooks ALTER COLUMN id SET DEFAULT nextval('cookbooks_id_seq'::regclass);


--
-- Name: id; Type: DEFAULT; Schema: goiardi; Owner: -
--

ALTER TABLE ONLY data_bag_items ALTER COLUMN id SET DEFAULT nextval('data_bag_items_id_seq'::regclass);


--
-- Name: id; Type: DEFAULT; Schema: goiardi; Owner: -
--

ALTER TABLE ONLY data_bags ALTER COLUMN id SET DEFAULT nextval('data_bags_id_seq'::regclass);


--
-- Name: id; Type: DEFAULT; Schema: goiardi; Owner: -
--

ALTER TABLE ONLY environments ALTER COLUMN id SET DEFAULT nextval('environments_id_seq'::regclass);


--
-- Name: id; Type: DEFAULT; Schema: goiardi; Owner: -
--

ALTER TABLE ONLY file_checksums ALTER COLUMN id SET DEFAULT nextval('file_checksums_id_seq'::regclass);


--
-- Name: id; Type: DEFAULT; Schema: goiardi; Owner: -
--

ALTER TABLE ONLY log_infos ALTER COLUMN id SET DEFAULT nextval('log_infos_id_seq'::regclass);


--
-- Name: id; Type: DEFAULT; Schema: goiardi; Owner: -
--

ALTER TABLE ONLY node_statuses ALTER COLUMN id SET DEFAULT nextval('node_statuses_id_seq'::regclass);


--
-- Name: id; Type: DEFAULT; Schema: goiardi; Owner: -
--

ALTER TABLE ONLY nodes ALTER COLUMN id SET DEFAULT nextval('nodes_id_seq'::regclass);


--
-- Name: id; Type: DEFAULT; Schema: goiardi; Owner: -
--

ALTER TABLE ONLY organizations ALTER COLUMN id SET DEFAULT nextval('organizations_id_seq'::regclass);


--
-- Name: id; Type: DEFAULT; Schema: goiardi; Owner: -
--

ALTER TABLE ONLY reports ALTER COLUMN id SET DEFAULT nextval('reports_id_seq'::regclass);


--
-- Name: id; Type: DEFAULT; Schema: goiardi; Owner: -
--

ALTER TABLE ONLY roles ALTER COLUMN id SET DEFAULT nextval('roles_id_seq'::regclass);


--
-- Name: id; Type: DEFAULT; Schema: goiardi; Owner: -
--

ALTER TABLE ONLY sandboxes ALTER COLUMN id SET DEFAULT nextval('sandboxes_id_seq'::regclass);


--
-- Name: id; Type: DEFAULT; Schema: goiardi; Owner: -
--

ALTER TABLE ONLY search_collections ALTER COLUMN id SET DEFAULT nextval('search_collections_id_seq'::regclass);


--
-- Name: id; Type: DEFAULT; Schema: goiardi; Owner: -
--

ALTER TABLE ONLY search_items ALTER COLUMN id SET DEFAULT nextval('search_items_id_seq'::regclass);


--
-- Name: id; Type: DEFAULT; Schema: goiardi; Owner: -
--

ALTER TABLE ONLY shovey_run_streams ALTER COLUMN id SET DEFAULT nextval('shovey_run_streams_id_seq'::regclass);


--
-- Name: id; Type: DEFAULT; Schema: goiardi; Owner: -
--

ALTER TABLE ONLY shovey_runs ALTER COLUMN id SET DEFAULT nextval('shovey_runs_id_seq'::regclass);


--
-- Name: id; Type: DEFAULT; Schema: goiardi; Owner: -
--

ALTER TABLE ONLY shoveys ALTER COLUMN id SET DEFAULT nextval('shoveys_id_seq'::regclass);


--
-- Name: id; Type: DEFAULT; Schema: goiardi; Owner: -
--

ALTER TABLE ONLY users ALTER COLUMN id SET DEFAULT nextval('users_id_seq'::regclass);


--
-- Data for Name: clients; Type: TABLE DATA; Schema: goiardi; Owner: -
--

COPY clients (id, name, nodename, validator, admin, organization_id, public_key, certificate, created_at, updated_at) FROM stdin;
\.


--
-- Name: clients_id_seq; Type: SEQUENCE SET; Schema: goiardi; Owner: -
--

SELECT pg_catalog.setval('clients_id_seq', 1, false);


--
-- Data for Name: cookbook_versions; Type: TABLE DATA; Schema: goiardi; Owner: -
--

COPY cookbook_versions (id, cookbook_id, major_ver, minor_ver, patch_ver, frozen, metadata, definitions, libraries, attributes, recipes, providers, resources, templates, root_files, files, created_at, updated_at) FROM stdin;
\.


--
-- Name: cookbook_versions_id_seq; Type: SEQUENCE SET; Schema: goiardi; Owner: -
--

SELECT pg_catalog.setval('cookbook_versions_id_seq', 1, false);


--
-- Data for Name: cookbooks; Type: TABLE DATA; Schema: goiardi; Owner: -
--

COPY cookbooks (id, name, organization_id, created_at, updated_at) FROM stdin;
\.


--
-- Name: cookbooks_id_seq; Type: SEQUENCE SET; Schema: goiardi; Owner: -
--

SELECT pg_catalog.setval('cookbooks_id_seq', 1, false);


--
-- Data for Name: data_bag_items; Type: TABLE DATA; Schema: goiardi; Owner: -
--

COPY data_bag_items (id, name, orig_name, data_bag_id, raw_data, created_at, updated_at) FROM stdin;
\.


--
-- Name: data_bag_items_id_seq; Type: SEQUENCE SET; Schema: goiardi; Owner: -
--

SELECT pg_catalog.setval('data_bag_items_id_seq', 1, false);


--
-- Data for Name: data_bags; Type: TABLE DATA; Schema: goiardi; Owner: -
--

COPY data_bags (id, name, organization_id, created_at, updated_at) FROM stdin;
\.


--
-- Name: data_bags_id_seq; Type: SEQUENCE SET; Schema: goiardi; Owner: -
--

SELECT pg_catalog.setval('data_bags_id_seq', 1, false);


--
-- Data for Name: environments; Type: TABLE DATA; Schema: goiardi; Owner: -
--

COPY environments (id, name, organization_id, description, default_attr, override_attr, cookbook_vers, created_at, updated_at) FROM stdin;
1	_default	1	The default Chef environment	\N	\N	\N	2015-07-23 00:27:18.493865-07	2015-07-23 00:27:18.493865-07
\.


--
-- Name: environments_id_seq; Type: SEQUENCE SET; Schema: goiardi; Owner: -
--

SELECT pg_catalog.setval('environments_id_seq', 1, false);


--
-- Data for Name: file_checksums; Type: TABLE DATA; Schema: goiardi; Owner: -
--

COPY file_checksums (id, organization_id, checksum) FROM stdin;
\.


--
-- Name: file_checksums_id_seq; Type: SEQUENCE SET; Schema: goiardi; Owner: -
--

SELECT pg_catalog.setval('file_checksums_id_seq', 1, false);


--
-- Data for Name: log_infos; Type: TABLE DATA; Schema: goiardi; Owner: -
--

COPY log_infos (id, actor_id, actor_info, actor_type, organization_id, "time", action, object_type, object_name, extended_info) FROM stdin;
\.


--
-- Name: log_infos_id_seq; Type: SEQUENCE SET; Schema: goiardi; Owner: -
--

SELECT pg_catalog.setval('log_infos_id_seq', 1, false);


--
-- Data for Name: node_statuses; Type: TABLE DATA; Schema: goiardi; Owner: -
--

COPY node_statuses (id, node_id, status, updated_at) FROM stdin;
\.


--
-- Name: node_statuses_id_seq; Type: SEQUENCE SET; Schema: goiardi; Owner: -
--

SELECT pg_catalog.setval('node_statuses_id_seq', 1, false);


--
-- Data for Name: nodes; Type: TABLE DATA; Schema: goiardi; Owner: -
--

COPY nodes (id, name, organization_id, chef_environment, run_list, automatic_attr, normal_attr, default_attr, override_attr, created_at, updated_at, is_down) FROM stdin;
\.


--
-- Name: nodes_id_seq; Type: SEQUENCE SET; Schema: goiardi; Owner: -
--

SELECT pg_catalog.setval('nodes_id_seq', 1, false);


--
-- Data for Name: organizations; Type: TABLE DATA; Schema: goiardi; Owner: -
--

COPY organizations (id, name, description, created_at, updated_at) FROM stdin;
1	default	\N	2015-07-23 00:27:18.721637-07	2015-07-23 00:27:18.721637-07
\.


--
-- Name: organizations_id_seq; Type: SEQUENCE SET; Schema: goiardi; Owner: -
--

SELECT pg_catalog.setval('organizations_id_seq', 1, true);


--
-- Data for Name: reports; Type: TABLE DATA; Schema: goiardi; Owner: -
--

COPY reports (id, run_id, node_name, organization_id, start_time, end_time, total_res_count, status, run_list, resources, data, created_at, updated_at) FROM stdin;
\.


--
-- Name: reports_id_seq; Type: SEQUENCE SET; Schema: goiardi; Owner: -
--

SELECT pg_catalog.setval('reports_id_seq', 1, false);


--
-- Data for Name: roles; Type: TABLE DATA; Schema: goiardi; Owner: -
--

COPY roles (id, name, organization_id, description, run_list, env_run_lists, default_attr, override_attr, created_at, updated_at) FROM stdin;
\.


--
-- Name: roles_id_seq; Type: SEQUENCE SET; Schema: goiardi; Owner: -
--

SELECT pg_catalog.setval('roles_id_seq', 1, false);


--
-- Data for Name: sandboxes; Type: TABLE DATA; Schema: goiardi; Owner: -
--

COPY sandboxes (id, sbox_id, organization_id, creation_time, checksums, completed) FROM stdin;
\.


--
-- Name: sandboxes_id_seq; Type: SEQUENCE SET; Schema: goiardi; Owner: -
--

SELECT pg_catalog.setval('sandboxes_id_seq', 1, false);


--
-- Data for Name: search_collections; Type: TABLE DATA; Schema: goiardi; Owner: -
--

COPY search_collections (id, organization_id, name) FROM stdin;
\.


--
-- Name: search_collections_id_seq; Type: SEQUENCE SET; Schema: goiardi; Owner: -
--

SELECT pg_catalog.setval('search_collections_id_seq', 1, false);


--
-- Data for Name: search_items; Type: TABLE DATA; Schema: goiardi; Owner: -
--

COPY search_items (id, organization_id, search_collection_id, item_name, value, path) FROM stdin;
\.


--
-- Name: search_items_id_seq; Type: SEQUENCE SET; Schema: goiardi; Owner: -
--

SELECT pg_catalog.setval('search_items_id_seq', 1, false);


--
-- Data for Name: shovey_run_streams; Type: TABLE DATA; Schema: goiardi; Owner: -
--

COPY shovey_run_streams (id, shovey_run_id, seq, output_type, output, is_last, created_at) FROM stdin;
\.


--
-- Name: shovey_run_streams_id_seq; Type: SEQUENCE SET; Schema: goiardi; Owner: -
--

SELECT pg_catalog.setval('shovey_run_streams_id_seq', 1, false);


--
-- Data for Name: shovey_runs; Type: TABLE DATA; Schema: goiardi; Owner: -
--

COPY shovey_runs (id, shovey_uuid, shovey_id, node_name, status, ack_time, end_time, error, exit_status) FROM stdin;
\.


--
-- Name: shovey_runs_id_seq; Type: SEQUENCE SET; Schema: goiardi; Owner: -
--

SELECT pg_catalog.setval('shovey_runs_id_seq', 1, false);


--
-- Data for Name: shoveys; Type: TABLE DATA; Schema: goiardi; Owner: -
--

COPY shoveys (id, run_id, command, status, timeout, quorum, created_at, updated_at, organization_id) FROM stdin;
\.


--
-- Name: shoveys_id_seq; Type: SEQUENCE SET; Schema: goiardi; Owner: -
--

SELECT pg_catalog.setval('shoveys_id_seq', 1, false);


--
-- Data for Name: users; Type: TABLE DATA; Schema: goiardi; Owner: -
--

COPY users (id, name, displayname, email, admin, public_key, passwd, salt, created_at, updated_at) FROM stdin;
\.


--
-- Name: users_id_seq; Type: SEQUENCE SET; Schema: goiardi; Owner: -
--

SELECT pg_catalog.setval('users_id_seq', 1, false);


SET search_path = sqitch, pg_catalog;

--
-- Data for Name: changes; Type: TABLE DATA; Schema: sqitch; Owner: -
--

COPY changes (change_id, change, project, note, committed_at, committer_name, committer_email, planned_at, planner_name, planner_email) FROM stdin;
c89b0e25c808b327036c88e6c9750c7526314c86	goiardi_schema	goiardi_postgres	Add schema for goiardi-postgres	2015-07-23 00:27:18.48188-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-27 14:09:07-07	Jeremy Bingham	jbingham@gmail.com
367c28670efddf25455b9fd33c23a5a278b08bb4	environments	goiardi_postgres	Environments for postgres	2015-07-23 00:27:18.503498-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 00:40:11-07	Jeremy Bingham	jbingham@gmail.com
911c456769628c817340ee77fc8d2b7c1d697782	nodes	goiardi_postgres	Create node table	2015-07-23 00:27:18.524367-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 10:37:46-07	Jeremy Bingham	jbingham@gmail.com
faa3571aa479de60f25785e707433b304ba3d2c7	clients	goiardi_postgres	Create client table	2015-07-23 00:27:18.543524-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 11:05:33-07	Jeremy Bingham	jbingham@gmail.com
bb82d8869ffca8ba3d03a1502c50dbb3eee7a2e0	users	goiardi_postgres	Create user table	2015-07-23 00:27:18.562815-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 11:15:02-07	Jeremy Bingham	jbingham@gmail.com
138bc49d92c0bbb024cea41532a656f2d7f9b072	cookbooks	goiardi_postgres	Create cookbook  table	2015-07-23 00:27:18.58192-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 11:27:27-07	Jeremy Bingham	jbingham@gmail.com
f529038064a0259bdecbdab1f9f665e17ddb6136	cookbook_versions	goiardi_postgres	Create cookbook versions table	2015-07-23 00:27:18.601697-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 11:31:34-07	Jeremy Bingham	jbingham@gmail.com
85483913f96710c1267c6abacb6568cef9327f15	data_bags	goiardi_postgres	Create cookbook data bags table	2015-07-23 00:27:18.620747-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 11:42:04-07	Jeremy Bingham	jbingham@gmail.com
feddf91b62caed36c790988bd29222591980433b	data_bag_items	goiardi_postgres	Create data bag items table	2015-07-23 00:27:18.642222-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 12:02:31-07	Jeremy Bingham	jbingham@gmail.com
6a4489d9436ba1541d272700b303410cc906b08f	roles	goiardi_postgres	Create roles table	2015-07-23 00:27:18.662294-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 12:09:28-07	Jeremy Bingham	jbingham@gmail.com
c4b32778f2911930f583ce15267aade320ac4dcd	sandboxes	goiardi_postgres	Create sandboxes table	2015-07-23 00:27:18.686552-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 12:14:48-07	Jeremy Bingham	jbingham@gmail.com
81003655b93b41359804027fc202788aa0ddd9a9	log_infos	goiardi_postgres	Create log_infos table	2015-07-23 00:27:18.710472-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 12:19:10-07	Jeremy Bingham	jbingham@gmail.com
fce5b7aeed2ad742de1309d7841577cff19475a7	organizations	goiardi_postgres	Create organizations table	2015-07-23 00:27:18.729267-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 12:46:28-07	Jeremy Bingham	jbingham@gmail.com
f2621482d1c130ea8fee15d09f966685409bf67c	file_checksums	goiardi_postgres	Create file checksums table	2015-07-23 00:27:18.746218-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 12:49:19-07	Jeremy Bingham	jbingham@gmail.com
db1eb360cd5e6449a468ceb781d82b45dafb5c2d	reports	goiardi_postgres	Create reports table	2015-07-23 00:27:18.766549-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 13:02:49-07	Jeremy Bingham	jbingham@gmail.com
c8b38382f7e5a18f36c621327f59205aa8aa9849	client_insert_duplicate	goiardi_postgres	Function to emulate insert ... on duplicate update for clients	2015-07-23 00:27:18.78171-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 23:00:04-07	Jeremy Bingham	jbingham@gmail.com
30774a960a0efb6adfbb1d526b8cdb1a45c7d039	client_rename	goiardi_postgres	Function to rename clients	2015-07-23 00:27:18.796067-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-30 10:22:50-07	Jeremy Bingham	jbingham@gmail.com
2d1fdc8128b0632e798df7346e76f122ed5915ec	user_insert_duplicate	goiardi_postgres	Function to emulate insert ... on duplicate update for clients	2015-07-23 00:27:18.8111-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-30 13:07:46-07	Jeremy Bingham	jbingham@gmail.com
f336c149ab32530c9c6ae4408c11558a635f39a1	user_rename	goiardi_postgres	Function to rename users	2015-07-23 00:27:18.825697-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-30 13:15:45-07	Jeremy Bingham	jbingham@gmail.com
841a7d554d44f9d0d0b8a1a5a9d0a06ce71a2453	cookbook_insert_update	goiardi_postgres	Cookbook insert/update	2015-07-23 00:27:18.840739-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-30 23:55:23-07	Jeremy Bingham	jbingham@gmail.com
085e2f6281914c9fa6521d59fea81f16c106b59f	cookbook_versions_insert_update	goiardi_postgres	Cookbook versions insert/update	2015-07-23 00:27:18.855742-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-30 23:56:05-07	Jeremy Bingham	jbingham@gmail.com
04bea39d649e4187d9579bd946fd60f760240d10	data_bag_insert_update	goiardi_postgres	Insert/update data bags	2015-07-23 00:27:18.870671-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-31 23:25:44-07	Jeremy Bingham	jbingham@gmail.com
092885e8b5d94a9c1834bf309e02dc0f955ff053	environment_insert_update	goiardi_postgres	Insert/update environments	2015-07-23 00:27:18.886046-07	Jeremy Bingham	jeremy@goiardi.gl	2014-06-01 12:55:34-07	Jeremy Bingham	jbingham@gmail.com
6d9587fa4275827c93ca9d7e0166ad1887b76cad	file_checksum_insert_ignore	goiardi_postgres	Insert ignore for file checksums	2015-07-23 00:27:18.902197-07	Jeremy Bingham	jeremy@goiardi.gl	2014-06-01 23:13:48-07	Jeremy Bingham	jbingham@gmail.com
82a95e5e6cbd8ba51fea33506e1edb2a12e37a92	node_insert_update	goiardi_postgres	Insert/update for nodes	2015-07-23 00:27:18.917661-07	Jeremy Bingham	jeremy@goiardi.gl	2014-06-01 23:25:20-07	Jeremy Bingham	jbingham@gmail.com
d052a8267a6512581e5cab1f89a2456f279727b9	report_insert_update	goiardi_postgres	Insert/update for reports	2015-07-23 00:27:18.932154-07	Jeremy Bingham	jeremy@goiardi.gl	2014-06-02 10:10:25-07	Jeremy Bingham	jbingham@gmail.com
acf76029633d50febbec7c4763b7173078eddaf7	role_insert_update	goiardi_postgres	Insert/update for roles	2015-07-23 00:27:18.949569-07	Jeremy Bingham	jeremy@goiardi.gl	2014-06-02 10:27:32-07	Jeremy Bingham	jbingham@gmail.com
b8ef36df686397ecb0fe67eb097e84aa0d78ac6b	sandbox_insert_update	goiardi_postgres	Insert/update for sandboxes	2015-07-23 00:27:18.965343-07	Jeremy Bingham	jeremy@goiardi.gl	2014-06-02 10:34:39-07	Jeremy Bingham	jbingham@gmail.com
93dbbda50a25da0a586e89ccee8fcfa2ddcb7c64	data_bag_item_insert	goiardi_postgres	Insert for data bag items	2015-07-23 00:27:18.981467-07	Jeremy Bingham	jeremy@goiardi.gl	2014-06-02 14:03:22-07	Jeremy Bingham	jbingham@gmail.com
c80c561c22f6e139165cdb338c7ce6fff8ff268d	bytea_to_json	goiardi_postgres	Change most postgres bytea fields to json, because in this peculiar case json is way faster than gob	2015-07-23 00:27:19.04661-07	Jeremy Bingham	jeremy@goiardi.gl	2014-07-20 02:41:22-07	Jeremy Bingham	jbingham@gmail.com
9966894e0fc0da573243f6a3c0fc1432a2b63043	joined_cookbkook_version	goiardi_postgres	a convenient view for joined versions for cookbook versions, adapted from erchef's joined_cookbook_version	2015-07-23 00:27:19.065968-07	Jeremy Bingham	jeremy@goiardi.gl	2014-07-20 03:21:28-07	Jeremy Bingham	jbingham@gmail.com
163ba4a496b9b4210d335e0e4ea5368a9ea8626c	node_statuses	goiardi_postgres	Create node_status table for node statuses	2015-07-23 00:27:19.085698-07	Jeremy Bingham	jeremy@goiardi.gl	2014-07-10 23:01:54-07	Jeremy Bingham	jeremy@terqa.local
8bb822f391b499585cfb2fc7248be469b0200682	node_status_insert	goiardi_postgres	insert function for node_statuses	2015-07-23 00:27:19.105089-07	Jeremy Bingham	jeremy@goiardi.gl	2014-07-11 00:01:31-07	Jeremy Bingham	jeremy@terqa.local
7c429aac08527adc774767584201f668408b04a6	add_down_column_nodes	goiardi_postgres	Add is_down column to the nodes table	2015-07-23 00:27:19.133986-07	Jeremy Bingham	jeremy@goiardi.gl	2014-07-15 20:18:05-07	Jeremy Bingham	jbingham@gmail.com
82bcace325dbdc905eb6e677f800d14a0506a216	shovey	goiardi_postgres	add shovey tables	2015-07-23 00:27:19.167069-07	Jeremy Bingham	jeremy@goiardi.gl	2014-07-15 22:07:12-07	Jeremy Bingham	jeremy@terqa.local
62046d2fb96bbaedce2406252d312766452551c0	node_latest_statuses	goiardi_postgres	Add a view to easily get nodes by their latest status	2015-07-23 00:27:19.183257-07	Jeremy Bingham	jeremy@goiardi.gl	2014-07-26 13:32:02-07	Jeremy Bingham	jbingham@gmail.com
68f90e1fd2aac6a117d7697626741a02b8d0ebbe	shovey_insert_update	goiardi_postgres	insert/update functions for shovey	2015-07-23 00:27:19.199314-07	Jeremy Bingham	jeremy@goiardi.gl	2014-08-27 00:46:20-07	Jeremy Bingham	jbingham@gmail.com
6f7aa2430e01cf33715828f1957d072cd5006d1c	ltree	goiardi_postgres	Add tables for ltree search for postgres	2015-07-23 00:27:19.273836-07	Jeremy Bingham	jeremy@goiardi.gl	2015-04-10 23:21:26-07	Jeremy Bingham	jeremy@goiardi.gl
e7eb33b00d2fb6302e0c3979e9cac6fb80da377e	ltree_del_col	goiardi_postgres	procedure for deleting search collections	2015-07-23 00:27:19.298245-07	Jeremy Bingham	jeremy@goiardi.gl	2015-04-12 12:33:15-07	Jeremy Bingham	jeremy@goiardi.gl
f49decbb15053ec5691093568450f642578ca460	ltree_del_item	goiardi_postgres	procedure for deleting search items	2015-07-23 00:27:19.316152-07	Jeremy Bingham	jeremy@goiardi.gl	2015-04-12 13:03:50-07	Jeremy Bingham	jeremy@goiardi.gl
\.


--
-- Data for Name: dependencies; Type: TABLE DATA; Schema: sqitch; Owner: -
--

COPY dependencies (change_id, type, dependency, dependency_id) FROM stdin;
367c28670efddf25455b9fd33c23a5a278b08bb4	require	goiardi_schema	c89b0e25c808b327036c88e6c9750c7526314c86
911c456769628c817340ee77fc8d2b7c1d697782	require	goiardi_schema	c89b0e25c808b327036c88e6c9750c7526314c86
faa3571aa479de60f25785e707433b304ba3d2c7	require	goiardi_schema	c89b0e25c808b327036c88e6c9750c7526314c86
bb82d8869ffca8ba3d03a1502c50dbb3eee7a2e0	require	goiardi_schema	c89b0e25c808b327036c88e6c9750c7526314c86
138bc49d92c0bbb024cea41532a656f2d7f9b072	require	goiardi_schema	c89b0e25c808b327036c88e6c9750c7526314c86
f529038064a0259bdecbdab1f9f665e17ddb6136	require	cookbooks	138bc49d92c0bbb024cea41532a656f2d7f9b072
f529038064a0259bdecbdab1f9f665e17ddb6136	require	goiardi_schema	c89b0e25c808b327036c88e6c9750c7526314c86
85483913f96710c1267c6abacb6568cef9327f15	require	goiardi_schema	c89b0e25c808b327036c88e6c9750c7526314c86
feddf91b62caed36c790988bd29222591980433b	require	data_bags	85483913f96710c1267c6abacb6568cef9327f15
feddf91b62caed36c790988bd29222591980433b	require	goiardi_schema	c89b0e25c808b327036c88e6c9750c7526314c86
6a4489d9436ba1541d272700b303410cc906b08f	require	goiardi_schema	c89b0e25c808b327036c88e6c9750c7526314c86
c4b32778f2911930f583ce15267aade320ac4dcd	require	goiardi_schema	c89b0e25c808b327036c88e6c9750c7526314c86
81003655b93b41359804027fc202788aa0ddd9a9	require	clients	faa3571aa479de60f25785e707433b304ba3d2c7
81003655b93b41359804027fc202788aa0ddd9a9	require	users	bb82d8869ffca8ba3d03a1502c50dbb3eee7a2e0
81003655b93b41359804027fc202788aa0ddd9a9	require	goiardi_schema	c89b0e25c808b327036c88e6c9750c7526314c86
c8b38382f7e5a18f36c621327f59205aa8aa9849	require	clients	faa3571aa479de60f25785e707433b304ba3d2c7
c8b38382f7e5a18f36c621327f59205aa8aa9849	require	goiardi_schema	c89b0e25c808b327036c88e6c9750c7526314c86
30774a960a0efb6adfbb1d526b8cdb1a45c7d039	require	clients	faa3571aa479de60f25785e707433b304ba3d2c7
30774a960a0efb6adfbb1d526b8cdb1a45c7d039	require	goiardi_schema	c89b0e25c808b327036c88e6c9750c7526314c86
2d1fdc8128b0632e798df7346e76f122ed5915ec	require	users	bb82d8869ffca8ba3d03a1502c50dbb3eee7a2e0
2d1fdc8128b0632e798df7346e76f122ed5915ec	require	goiardi_schema	c89b0e25c808b327036c88e6c9750c7526314c86
f336c149ab32530c9c6ae4408c11558a635f39a1	require	users	bb82d8869ffca8ba3d03a1502c50dbb3eee7a2e0
f336c149ab32530c9c6ae4408c11558a635f39a1	require	goiardi_schema	c89b0e25c808b327036c88e6c9750c7526314c86
841a7d554d44f9d0d0b8a1a5a9d0a06ce71a2453	require	cookbooks	138bc49d92c0bbb024cea41532a656f2d7f9b072
841a7d554d44f9d0d0b8a1a5a9d0a06ce71a2453	require	goiardi_schema	c89b0e25c808b327036c88e6c9750c7526314c86
085e2f6281914c9fa6521d59fea81f16c106b59f	require	cookbook_versions	f529038064a0259bdecbdab1f9f665e17ddb6136
085e2f6281914c9fa6521d59fea81f16c106b59f	require	goiardi_schema	c89b0e25c808b327036c88e6c9750c7526314c86
04bea39d649e4187d9579bd946fd60f760240d10	require	data_bags	85483913f96710c1267c6abacb6568cef9327f15
04bea39d649e4187d9579bd946fd60f760240d10	require	goiardi_schema	c89b0e25c808b327036c88e6c9750c7526314c86
092885e8b5d94a9c1834bf309e02dc0f955ff053	require	environments	367c28670efddf25455b9fd33c23a5a278b08bb4
092885e8b5d94a9c1834bf309e02dc0f955ff053	require	goiardi_schema	c89b0e25c808b327036c88e6c9750c7526314c86
6d9587fa4275827c93ca9d7e0166ad1887b76cad	require	file_checksums	f2621482d1c130ea8fee15d09f966685409bf67c
6d9587fa4275827c93ca9d7e0166ad1887b76cad	require	goiardi_schema	c89b0e25c808b327036c88e6c9750c7526314c86
82a95e5e6cbd8ba51fea33506e1edb2a12e37a92	require	nodes	911c456769628c817340ee77fc8d2b7c1d697782
82a95e5e6cbd8ba51fea33506e1edb2a12e37a92	require	goiardi_schema	c89b0e25c808b327036c88e6c9750c7526314c86
d052a8267a6512581e5cab1f89a2456f279727b9	require	reports	db1eb360cd5e6449a468ceb781d82b45dafb5c2d
d052a8267a6512581e5cab1f89a2456f279727b9	require	goiardi_schema	c89b0e25c808b327036c88e6c9750c7526314c86
acf76029633d50febbec7c4763b7173078eddaf7	require	roles	6a4489d9436ba1541d272700b303410cc906b08f
acf76029633d50febbec7c4763b7173078eddaf7	require	goiardi_schema	c89b0e25c808b327036c88e6c9750c7526314c86
b8ef36df686397ecb0fe67eb097e84aa0d78ac6b	require	sandboxes	c4b32778f2911930f583ce15267aade320ac4dcd
b8ef36df686397ecb0fe67eb097e84aa0d78ac6b	require	goiardi_schema	c89b0e25c808b327036c88e6c9750c7526314c86
93dbbda50a25da0a586e89ccee8fcfa2ddcb7c64	require	data_bag_items	feddf91b62caed36c790988bd29222591980433b
93dbbda50a25da0a586e89ccee8fcfa2ddcb7c64	require	data_bags	85483913f96710c1267c6abacb6568cef9327f15
93dbbda50a25da0a586e89ccee8fcfa2ddcb7c64	require	goiardi_schema	c89b0e25c808b327036c88e6c9750c7526314c86
163ba4a496b9b4210d335e0e4ea5368a9ea8626c	require	nodes	911c456769628c817340ee77fc8d2b7c1d697782
8bb822f391b499585cfb2fc7248be469b0200682	require	node_statuses	163ba4a496b9b4210d335e0e4ea5368a9ea8626c
7c429aac08527adc774767584201f668408b04a6	require	nodes	911c456769628c817340ee77fc8d2b7c1d697782
62046d2fb96bbaedce2406252d312766452551c0	require	node_statuses	163ba4a496b9b4210d335e0e4ea5368a9ea8626c
68f90e1fd2aac6a117d7697626741a02b8d0ebbe	require	shovey	82bcace325dbdc905eb6e677f800d14a0506a216
\.


--
-- Data for Name: events; Type: TABLE DATA; Schema: sqitch; Owner: -
--

COPY events (event, change_id, change, project, note, requires, conflicts, tags, committed_at, committer_name, committer_email, planned_at, planner_name, planner_email) FROM stdin;
deploy	c89b0e25c808b327036c88e6c9750c7526314c86	goiardi_schema	goiardi_postgres	Add schema for goiardi-postgres	{}	{}	{}	2015-07-15 12:39:14.177246-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-27 14:09:07-07	Jeremy Bingham	jbingham@gmail.com
deploy	367c28670efddf25455b9fd33c23a5a278b08bb4	environments	goiardi_postgres	Environments for postgres	{goiardi_schema}	{}	{}	2015-07-15 12:39:14.198975-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 00:40:11-07	Jeremy Bingham	jbingham@gmail.com
deploy	911c456769628c817340ee77fc8d2b7c1d697782	nodes	goiardi_postgres	Create node table	{goiardi_schema}	{}	{}	2015-07-15 12:39:14.22012-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 10:37:46-07	Jeremy Bingham	jbingham@gmail.com
deploy	faa3571aa479de60f25785e707433b304ba3d2c7	clients	goiardi_postgres	Create client table	{goiardi_schema}	{}	{}	2015-07-15 12:39:14.243257-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 11:05:33-07	Jeremy Bingham	jbingham@gmail.com
deploy	bb82d8869ffca8ba3d03a1502c50dbb3eee7a2e0	users	goiardi_postgres	Create user table	{goiardi_schema}	{}	{}	2015-07-15 12:39:14.263264-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 11:15:02-07	Jeremy Bingham	jbingham@gmail.com
deploy	138bc49d92c0bbb024cea41532a656f2d7f9b072	cookbooks	goiardi_postgres	Create cookbook  table	{goiardi_schema}	{}	{}	2015-07-15 12:39:14.289215-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 11:27:27-07	Jeremy Bingham	jbingham@gmail.com
deploy	f529038064a0259bdecbdab1f9f665e17ddb6136	cookbook_versions	goiardi_postgres	Create cookbook versions table	{cookbooks,goiardi_schema}	{}	{}	2015-07-15 12:39:14.309606-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 11:31:34-07	Jeremy Bingham	jbingham@gmail.com
deploy	85483913f96710c1267c6abacb6568cef9327f15	data_bags	goiardi_postgres	Create cookbook data bags table	{goiardi_schema}	{}	{}	2015-07-15 12:39:14.329491-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 11:42:04-07	Jeremy Bingham	jbingham@gmail.com
deploy	feddf91b62caed36c790988bd29222591980433b	data_bag_items	goiardi_postgres	Create data bag items table	{data_bags,goiardi_schema}	{}	{}	2015-07-15 12:39:14.350839-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 12:02:31-07	Jeremy Bingham	jbingham@gmail.com
deploy	6a4489d9436ba1541d272700b303410cc906b08f	roles	goiardi_postgres	Create roles table	{goiardi_schema}	{}	{}	2015-07-15 12:39:14.36979-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 12:09:28-07	Jeremy Bingham	jbingham@gmail.com
deploy	c4b32778f2911930f583ce15267aade320ac4dcd	sandboxes	goiardi_postgres	Create sandboxes table	{goiardi_schema}	{}	{}	2015-07-15 12:39:14.38949-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 12:14:48-07	Jeremy Bingham	jbingham@gmail.com
deploy	81003655b93b41359804027fc202788aa0ddd9a9	log_infos	goiardi_postgres	Create log_infos table	{clients,users,goiardi_schema}	{}	{}	2015-07-15 12:39:14.415874-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 12:19:10-07	Jeremy Bingham	jbingham@gmail.com
deploy	fce5b7aeed2ad742de1309d7841577cff19475a7	organizations	goiardi_postgres	Create organizations table	{}	{}	{}	2015-07-15 12:39:14.443603-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 12:46:28-07	Jeremy Bingham	jbingham@gmail.com
deploy	f2621482d1c130ea8fee15d09f966685409bf67c	file_checksums	goiardi_postgres	Create file checksums table	{}	{}	{}	2015-07-15 12:39:14.46217-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 12:49:19-07	Jeremy Bingham	jbingham@gmail.com
deploy	db1eb360cd5e6449a468ceb781d82b45dafb5c2d	reports	goiardi_postgres	Create reports table	{}	{}	{}	2015-07-15 12:39:14.486365-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 13:02:49-07	Jeremy Bingham	jbingham@gmail.com
deploy	c8b38382f7e5a18f36c621327f59205aa8aa9849	client_insert_duplicate	goiardi_postgres	Function to emulate insert ... on duplicate update for clients	{clients,goiardi_schema}	{}	{}	2015-07-15 12:39:14.505176-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 23:00:04-07	Jeremy Bingham	jbingham@gmail.com
deploy	30774a960a0efb6adfbb1d526b8cdb1a45c7d039	client_rename	goiardi_postgres	Function to rename clients	{clients,goiardi_schema}	{}	{}	2015-07-15 12:39:14.520597-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-30 10:22:50-07	Jeremy Bingham	jbingham@gmail.com
deploy	2d1fdc8128b0632e798df7346e76f122ed5915ec	user_insert_duplicate	goiardi_postgres	Function to emulate insert ... on duplicate update for clients	{users,goiardi_schema}	{}	{}	2015-07-15 12:39:14.53599-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-30 13:07:46-07	Jeremy Bingham	jbingham@gmail.com
deploy	f336c149ab32530c9c6ae4408c11558a635f39a1	user_rename	goiardi_postgres	Function to rename users	{users,goiardi_schema}	{}	{}	2015-07-15 12:39:14.551319-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-30 13:15:45-07	Jeremy Bingham	jbingham@gmail.com
deploy	841a7d554d44f9d0d0b8a1a5a9d0a06ce71a2453	cookbook_insert_update	goiardi_postgres	Cookbook insert/update	{cookbooks,goiardi_schema}	{}	{}	2015-07-15 12:39:14.568304-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-30 23:55:23-07	Jeremy Bingham	jbingham@gmail.com
deploy	085e2f6281914c9fa6521d59fea81f16c106b59f	cookbook_versions_insert_update	goiardi_postgres	Cookbook versions insert/update	{cookbook_versions,goiardi_schema}	{}	{}	2015-07-15 12:39:14.582689-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-30 23:56:05-07	Jeremy Bingham	jbingham@gmail.com
deploy	04bea39d649e4187d9579bd946fd60f760240d10	data_bag_insert_update	goiardi_postgres	Insert/update data bags	{data_bags,goiardi_schema}	{}	{}	2015-07-15 12:39:14.597733-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-31 23:25:44-07	Jeremy Bingham	jbingham@gmail.com
deploy	092885e8b5d94a9c1834bf309e02dc0f955ff053	environment_insert_update	goiardi_postgres	Insert/update environments	{environments,goiardi_schema}	{}	{}	2015-07-15 12:39:14.61305-07	Jeremy Bingham	jeremy@goiardi.gl	2014-06-01 12:55:34-07	Jeremy Bingham	jbingham@gmail.com
deploy	6d9587fa4275827c93ca9d7e0166ad1887b76cad	file_checksum_insert_ignore	goiardi_postgres	Insert ignore for file checksums	{file_checksums,goiardi_schema}	{}	{}	2015-07-15 12:39:14.628611-07	Jeremy Bingham	jeremy@goiardi.gl	2014-06-01 23:13:48-07	Jeremy Bingham	jbingham@gmail.com
deploy	82a95e5e6cbd8ba51fea33506e1edb2a12e37a92	node_insert_update	goiardi_postgres	Insert/update for nodes	{nodes,goiardi_schema}	{}	{}	2015-07-15 12:39:14.646583-07	Jeremy Bingham	jeremy@goiardi.gl	2014-06-01 23:25:20-07	Jeremy Bingham	jbingham@gmail.com
deploy	d052a8267a6512581e5cab1f89a2456f279727b9	report_insert_update	goiardi_postgres	Insert/update for reports	{reports,goiardi_schema}	{}	{}	2015-07-15 12:39:14.664987-07	Jeremy Bingham	jeremy@goiardi.gl	2014-06-02 10:10:25-07	Jeremy Bingham	jbingham@gmail.com
deploy	acf76029633d50febbec7c4763b7173078eddaf7	role_insert_update	goiardi_postgres	Insert/update for roles	{roles,goiardi_schema}	{}	{}	2015-07-15 12:39:14.680311-07	Jeremy Bingham	jeremy@goiardi.gl	2014-06-02 10:27:32-07	Jeremy Bingham	jbingham@gmail.com
deploy	b8ef36df686397ecb0fe67eb097e84aa0d78ac6b	sandbox_insert_update	goiardi_postgres	Insert/update for sandboxes	{sandboxes,goiardi_schema}	{}	{}	2015-07-15 12:39:14.695631-07	Jeremy Bingham	jeremy@goiardi.gl	2014-06-02 10:34:39-07	Jeremy Bingham	jbingham@gmail.com
deploy	93dbbda50a25da0a586e89ccee8fcfa2ddcb7c64	data_bag_item_insert	goiardi_postgres	Insert for data bag items	{data_bag_items,data_bags,goiardi_schema}	{}	{@v0.6.0}	2015-07-15 12:39:14.713437-07	Jeremy Bingham	jeremy@goiardi.gl	2014-06-02 14:03:22-07	Jeremy Bingham	jbingham@gmail.com
deploy	c80c561c22f6e139165cdb338c7ce6fff8ff268d	bytea_to_json	goiardi_postgres	Change most postgres bytea fields to json, because in this peculiar case json is way faster than gob	{}	{}	{}	2015-07-15 12:39:14.768081-07	Jeremy Bingham	jeremy@goiardi.gl	2014-07-20 02:41:22-07	Jeremy Bingham	jbingham@gmail.com
deploy	9966894e0fc0da573243f6a3c0fc1432a2b63043	joined_cookbkook_version	goiardi_postgres	a convenient view for joined versions for cookbook versions, adapted from erchef's joined_cookbook_version	{}	{}	{@v0.7.0}	2015-07-15 12:39:14.791647-07	Jeremy Bingham	jeremy@goiardi.gl	2014-07-20 03:21:28-07	Jeremy Bingham	jbingham@gmail.com
deploy	163ba4a496b9b4210d335e0e4ea5368a9ea8626c	node_statuses	goiardi_postgres	Create node_status table for node statuses	{nodes}	{}	{}	2015-07-15 12:39:14.812885-07	Jeremy Bingham	jeremy@goiardi.gl	2014-07-10 23:01:54-07	Jeremy Bingham	jeremy@terqa.local
deploy	8bb822f391b499585cfb2fc7248be469b0200682	node_status_insert	goiardi_postgres	insert function for node_statuses	{node_statuses}	{}	{}	2015-07-15 12:39:14.829711-07	Jeremy Bingham	jeremy@goiardi.gl	2014-07-11 00:01:31-07	Jeremy Bingham	jeremy@terqa.local
deploy	7c429aac08527adc774767584201f668408b04a6	add_down_column_nodes	goiardi_postgres	Add is_down column to the nodes table	{nodes}	{}	{}	2015-07-15 12:39:14.852296-07	Jeremy Bingham	jeremy@goiardi.gl	2014-07-15 20:18:05-07	Jeremy Bingham	jbingham@gmail.com
deploy	82bcace325dbdc905eb6e677f800d14a0506a216	shovey	goiardi_postgres	add shovey tables	{}	{}	{}	2015-07-15 12:39:14.886095-07	Jeremy Bingham	jeremy@goiardi.gl	2014-07-15 22:07:12-07	Jeremy Bingham	jeremy@terqa.local
deploy	62046d2fb96bbaedce2406252d312766452551c0	node_latest_statuses	goiardi_postgres	Add a view to easily get nodes by their latest status	{node_statuses}	{}	{}	2015-07-15 12:39:14.909123-07	Jeremy Bingham	jeremy@goiardi.gl	2014-07-26 13:32:02-07	Jeremy Bingham	jbingham@gmail.com
deploy	68f90e1fd2aac6a117d7697626741a02b8d0ebbe	shovey_insert_update	goiardi_postgres	insert/update functions for shovey	{shovey}	{}	{@v0.8.0}	2015-07-15 12:39:14.929034-07	Jeremy Bingham	jeremy@goiardi.gl	2014-08-27 00:46:20-07	Jeremy Bingham	jbingham@gmail.com
deploy	6f7aa2430e01cf33715828f1957d072cd5006d1c	ltree	goiardi_postgres	Add tables for ltree search for postgres	{}	{}	{}	2015-07-15 12:39:14.986854-07	Jeremy Bingham	jeremy@goiardi.gl	2015-04-10 23:21:26-07	Jeremy Bingham	jeremy@goiardi.gl
deploy	e7eb33b00d2fb6302e0c3979e9cac6fb80da377e	ltree_del_col	goiardi_postgres	procedure for deleting search collections	{}	{}	{}	2015-07-15 12:39:15.002069-07	Jeremy Bingham	jeremy@goiardi.gl	2015-04-12 12:33:15-07	Jeremy Bingham	jeremy@goiardi.gl
deploy	f49decbb15053ec5691093568450f642578ca460	ltree_del_item	goiardi_postgres	procedure for deleting search items	{}	{}	{}	2015-07-15 12:39:15.017911-07	Jeremy Bingham	jeremy@goiardi.gl	2015-04-12 13:03:50-07	Jeremy Bingham	jeremy@goiardi.gl
revert	f49decbb15053ec5691093568450f642578ca460	ltree_del_item	goiardi_postgres	procedure for deleting search items	{}	{}	{}	2015-07-15 13:18:42.406427-07	Jeremy Bingham	jeremy@goiardi.gl	2015-04-12 13:03:50-07	Jeremy Bingham	jeremy@goiardi.gl
revert	e7eb33b00d2fb6302e0c3979e9cac6fb80da377e	ltree_del_col	goiardi_postgres	procedure for deleting search collections	{}	{}	{}	2015-07-15 13:18:42.421275-07	Jeremy Bingham	jeremy@goiardi.gl	2015-04-12 12:33:15-07	Jeremy Bingham	jeremy@goiardi.gl
revert	6f7aa2430e01cf33715828f1957d072cd5006d1c	ltree	goiardi_postgres	Add tables for ltree search for postgres	{}	{}	{}	2015-07-15 13:18:42.462634-07	Jeremy Bingham	jeremy@goiardi.gl	2015-04-10 23:21:26-07	Jeremy Bingham	jeremy@goiardi.gl
revert	68f90e1fd2aac6a117d7697626741a02b8d0ebbe	shovey_insert_update	goiardi_postgres	insert/update functions for shovey	{shovey}	{}	{@v0.8.0}	2015-07-15 13:18:42.479819-07	Jeremy Bingham	jeremy@goiardi.gl	2014-08-27 00:46:20-07	Jeremy Bingham	jbingham@gmail.com
revert	62046d2fb96bbaedce2406252d312766452551c0	node_latest_statuses	goiardi_postgres	Add a view to easily get nodes by their latest status	{node_statuses}	{}	{}	2015-07-15 13:18:42.494737-07	Jeremy Bingham	jeremy@goiardi.gl	2014-07-26 13:32:02-07	Jeremy Bingham	jbingham@gmail.com
revert	82bcace325dbdc905eb6e677f800d14a0506a216	shovey	goiardi_postgres	add shovey tables	{}	{}	{}	2015-07-15 13:18:42.548716-07	Jeremy Bingham	jeremy@goiardi.gl	2014-07-15 22:07:12-07	Jeremy Bingham	jeremy@terqa.local
revert	7c429aac08527adc774767584201f668408b04a6	add_down_column_nodes	goiardi_postgres	Add is_down column to the nodes table	{nodes}	{}	{}	2015-07-15 13:18:42.56677-07	Jeremy Bingham	jeremy@goiardi.gl	2014-07-15 20:18:05-07	Jeremy Bingham	jbingham@gmail.com
revert	8bb822f391b499585cfb2fc7248be469b0200682	node_status_insert	goiardi_postgres	insert function for node_statuses	{node_statuses}	{}	{}	2015-07-15 13:18:42.580739-07	Jeremy Bingham	jeremy@goiardi.gl	2014-07-11 00:01:31-07	Jeremy Bingham	jeremy@terqa.local
revert	163ba4a496b9b4210d335e0e4ea5368a9ea8626c	node_statuses	goiardi_postgres	Create node_status table for node statuses	{nodes}	{}	{}	2015-07-15 13:18:42.601292-07	Jeremy Bingham	jeremy@goiardi.gl	2014-07-10 23:01:54-07	Jeremy Bingham	jeremy@terqa.local
revert	9966894e0fc0da573243f6a3c0fc1432a2b63043	joined_cookbkook_version	goiardi_postgres	a convenient view for joined versions for cookbook versions, adapted from erchef's joined_cookbook_version	{}	{}	{@v0.7.0}	2015-07-15 13:18:42.614941-07	Jeremy Bingham	jeremy@goiardi.gl	2014-07-20 03:21:28-07	Jeremy Bingham	jbingham@gmail.com
revert	c80c561c22f6e139165cdb338c7ce6fff8ff268d	bytea_to_json	goiardi_postgres	Change most postgres bytea fields to json, because in this peculiar case json is way faster than gob	{}	{}	{}	2015-07-15 13:18:42.727462-07	Jeremy Bingham	jeremy@goiardi.gl	2014-07-20 02:41:22-07	Jeremy Bingham	jbingham@gmail.com
revert	911c456769628c817340ee77fc8d2b7c1d697782	nodes	goiardi_postgres	Create node table	{goiardi_schema}	{}	{}	2015-07-15 13:18:43.236375-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 10:37:46-07	Jeremy Bingham	jbingham@gmail.com
revert	93dbbda50a25da0a586e89ccee8fcfa2ddcb7c64	data_bag_item_insert	goiardi_postgres	Insert for data bag items	{data_bag_items,data_bags,goiardi_schema}	{}	{@v0.6.0}	2015-07-15 13:18:42.741559-07	Jeremy Bingham	jeremy@goiardi.gl	2014-06-02 14:03:22-07	Jeremy Bingham	jbingham@gmail.com
revert	b8ef36df686397ecb0fe67eb097e84aa0d78ac6b	sandbox_insert_update	goiardi_postgres	Insert/update for sandboxes	{sandboxes,goiardi_schema}	{}	{}	2015-07-15 13:18:42.758174-07	Jeremy Bingham	jeremy@goiardi.gl	2014-06-02 10:34:39-07	Jeremy Bingham	jbingham@gmail.com
revert	acf76029633d50febbec7c4763b7173078eddaf7	role_insert_update	goiardi_postgres	Insert/update for roles	{roles,goiardi_schema}	{}	{}	2015-07-15 13:18:42.771712-07	Jeremy Bingham	jeremy@goiardi.gl	2014-06-02 10:27:32-07	Jeremy Bingham	jbingham@gmail.com
revert	d052a8267a6512581e5cab1f89a2456f279727b9	report_insert_update	goiardi_postgres	Insert/update for reports	{reports,goiardi_schema}	{}	{}	2015-07-15 13:18:42.785603-07	Jeremy Bingham	jeremy@goiardi.gl	2014-06-02 10:10:25-07	Jeremy Bingham	jbingham@gmail.com
revert	82a95e5e6cbd8ba51fea33506e1edb2a12e37a92	node_insert_update	goiardi_postgres	Insert/update for nodes	{nodes,goiardi_schema}	{}	{}	2015-07-15 13:18:42.799901-07	Jeremy Bingham	jeremy@goiardi.gl	2014-06-01 23:25:20-07	Jeremy Bingham	jbingham@gmail.com
revert	6d9587fa4275827c93ca9d7e0166ad1887b76cad	file_checksum_insert_ignore	goiardi_postgres	Insert ignore for file checksums	{file_checksums,goiardi_schema}	{}	{}	2015-07-15 13:18:42.813323-07	Jeremy Bingham	jeremy@goiardi.gl	2014-06-01 23:13:48-07	Jeremy Bingham	jbingham@gmail.com
revert	092885e8b5d94a9c1834bf309e02dc0f955ff053	environment_insert_update	goiardi_postgres	Insert/update environments	{environments,goiardi_schema}	{}	{}	2015-07-15 13:18:42.82866-07	Jeremy Bingham	jeremy@goiardi.gl	2014-06-01 12:55:34-07	Jeremy Bingham	jbingham@gmail.com
revert	04bea39d649e4187d9579bd946fd60f760240d10	data_bag_insert_update	goiardi_postgres	Insert/update data bags	{data_bags,goiardi_schema}	{}	{}	2015-07-15 13:18:42.846548-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-31 23:25:44-07	Jeremy Bingham	jbingham@gmail.com
revert	085e2f6281914c9fa6521d59fea81f16c106b59f	cookbook_versions_insert_update	goiardi_postgres	Cookbook versions insert/update	{cookbook_versions,goiardi_schema}	{}	{}	2015-07-15 13:18:42.862049-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-30 23:56:05-07	Jeremy Bingham	jbingham@gmail.com
revert	841a7d554d44f9d0d0b8a1a5a9d0a06ce71a2453	cookbook_insert_update	goiardi_postgres	Cookbook insert/update	{cookbooks,goiardi_schema}	{}	{}	2015-07-15 13:18:42.877128-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-30 23:55:23-07	Jeremy Bingham	jbingham@gmail.com
revert	f336c149ab32530c9c6ae4408c11558a635f39a1	user_rename	goiardi_postgres	Function to rename users	{users,goiardi_schema}	{}	{}	2015-07-15 13:18:42.892029-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-30 13:15:45-07	Jeremy Bingham	jbingham@gmail.com
revert	2d1fdc8128b0632e798df7346e76f122ed5915ec	user_insert_duplicate	goiardi_postgres	Function to emulate insert ... on duplicate update for clients	{users,goiardi_schema}	{}	{}	2015-07-15 13:18:42.905348-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-30 13:07:46-07	Jeremy Bingham	jbingham@gmail.com
revert	30774a960a0efb6adfbb1d526b8cdb1a45c7d039	client_rename	goiardi_postgres	Function to rename clients	{clients,goiardi_schema}	{}	{}	2015-07-15 13:18:42.922625-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-30 10:22:50-07	Jeremy Bingham	jbingham@gmail.com
revert	c8b38382f7e5a18f36c621327f59205aa8aa9849	client_insert_duplicate	goiardi_postgres	Function to emulate insert ... on duplicate update for clients	{clients,goiardi_schema}	{}	{}	2015-07-15 13:18:42.936862-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 23:00:04-07	Jeremy Bingham	jbingham@gmail.com
revert	db1eb360cd5e6449a468ceb781d82b45dafb5c2d	reports	goiardi_postgres	Create reports table	{}	{}	{}	2015-07-15 13:18:42.956348-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 13:02:49-07	Jeremy Bingham	jbingham@gmail.com
revert	f2621482d1c130ea8fee15d09f966685409bf67c	file_checksums	goiardi_postgres	Create file checksums table	{}	{}	{}	2015-07-15 13:18:42.975228-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 12:49:19-07	Jeremy Bingham	jbingham@gmail.com
revert	fce5b7aeed2ad742de1309d7841577cff19475a7	organizations	goiardi_postgres	Create organizations table	{}	{}	{}	2015-07-15 13:18:43.003435-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 12:46:28-07	Jeremy Bingham	jbingham@gmail.com
revert	81003655b93b41359804027fc202788aa0ddd9a9	log_infos	goiardi_postgres	Create log_infos table	{clients,users,goiardi_schema}	{}	{}	2015-07-15 13:18:43.033715-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 12:19:10-07	Jeremy Bingham	jbingham@gmail.com
revert	c4b32778f2911930f583ce15267aade320ac4dcd	sandboxes	goiardi_postgres	Create sandboxes table	{goiardi_schema}	{}	{}	2015-07-15 13:18:43.051249-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 12:14:48-07	Jeremy Bingham	jbingham@gmail.com
revert	6a4489d9436ba1541d272700b303410cc906b08f	roles	goiardi_postgres	Create roles table	{goiardi_schema}	{}	{}	2015-07-15 13:18:43.069467-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 12:09:28-07	Jeremy Bingham	jbingham@gmail.com
revert	feddf91b62caed36c790988bd29222591980433b	data_bag_items	goiardi_postgres	Create data bag items table	{data_bags,goiardi_schema}	{}	{}	2015-07-15 13:18:43.088094-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 12:02:31-07	Jeremy Bingham	jbingham@gmail.com
revert	85483913f96710c1267c6abacb6568cef9327f15	data_bags	goiardi_postgres	Create cookbook data bags table	{goiardi_schema}	{}	{}	2015-07-15 13:18:43.1094-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 11:42:04-07	Jeremy Bingham	jbingham@gmail.com
revert	f529038064a0259bdecbdab1f9f665e17ddb6136	cookbook_versions	goiardi_postgres	Create cookbook versions table	{cookbooks,goiardi_schema}	{}	{}	2015-07-15 13:18:43.129278-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 11:31:34-07	Jeremy Bingham	jbingham@gmail.com
revert	138bc49d92c0bbb024cea41532a656f2d7f9b072	cookbooks	goiardi_postgres	Create cookbook  table	{goiardi_schema}	{}	{}	2015-07-15 13:18:43.15656-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 11:27:27-07	Jeremy Bingham	jbingham@gmail.com
revert	bb82d8869ffca8ba3d03a1502c50dbb3eee7a2e0	users	goiardi_postgres	Create user table	{goiardi_schema}	{}	{}	2015-07-15 13:18:43.184402-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 11:15:02-07	Jeremy Bingham	jbingham@gmail.com
revert	faa3571aa479de60f25785e707433b304ba3d2c7	clients	goiardi_postgres	Create client table	{goiardi_schema}	{}	{}	2015-07-15 13:18:43.212356-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 11:05:33-07	Jeremy Bingham	jbingham@gmail.com
revert	367c28670efddf25455b9fd33c23a5a278b08bb4	environments	goiardi_postgres	Environments for postgres	{goiardi_schema}	{}	{}	2015-07-15 13:18:43.25567-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 00:40:11-07	Jeremy Bingham	jbingham@gmail.com
revert	c89b0e25c808b327036c88e6c9750c7526314c86	goiardi_schema	goiardi_postgres	Add schema for goiardi-postgres	{}	{}	{}	2015-07-15 13:18:43.270498-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-27 14:09:07-07	Jeremy Bingham	jbingham@gmail.com
deploy	c89b0e25c808b327036c88e6c9750c7526314c86	goiardi_schema	goiardi_postgres	Add schema for goiardi-postgres	{}	{}	{}	2015-07-15 13:18:48.410186-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-27 14:09:07-07	Jeremy Bingham	jbingham@gmail.com
deploy	367c28670efddf25455b9fd33c23a5a278b08bb4	environments	goiardi_postgres	Environments for postgres	{goiardi_schema}	{}	{}	2015-07-15 13:18:48.434908-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 00:40:11-07	Jeremy Bingham	jbingham@gmail.com
deploy	911c456769628c817340ee77fc8d2b7c1d697782	nodes	goiardi_postgres	Create node table	{goiardi_schema}	{}	{}	2015-07-15 13:18:48.455143-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 10:37:46-07	Jeremy Bingham	jbingham@gmail.com
deploy	faa3571aa479de60f25785e707433b304ba3d2c7	clients	goiardi_postgres	Create client table	{goiardi_schema}	{}	{}	2015-07-15 13:18:48.474898-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 11:05:33-07	Jeremy Bingham	jbingham@gmail.com
deploy	bb82d8869ffca8ba3d03a1502c50dbb3eee7a2e0	users	goiardi_postgres	Create user table	{goiardi_schema}	{}	{}	2015-07-15 13:18:48.4942-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 11:15:02-07	Jeremy Bingham	jbingham@gmail.com
deploy	138bc49d92c0bbb024cea41532a656f2d7f9b072	cookbooks	goiardi_postgres	Create cookbook  table	{goiardi_schema}	{}	{}	2015-07-15 13:18:48.518002-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 11:27:27-07	Jeremy Bingham	jbingham@gmail.com
deploy	f529038064a0259bdecbdab1f9f665e17ddb6136	cookbook_versions	goiardi_postgres	Create cookbook versions table	{cookbooks,goiardi_schema}	{}	{}	2015-07-15 13:18:48.537621-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 11:31:34-07	Jeremy Bingham	jbingham@gmail.com
deploy	85483913f96710c1267c6abacb6568cef9327f15	data_bags	goiardi_postgres	Create cookbook data bags table	{goiardi_schema}	{}	{}	2015-07-15 13:18:48.561262-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 11:42:04-07	Jeremy Bingham	jbingham@gmail.com
deploy	feddf91b62caed36c790988bd29222591980433b	data_bag_items	goiardi_postgres	Create data bag items table	{data_bags,goiardi_schema}	{}	{}	2015-07-15 13:18:48.585579-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 12:02:31-07	Jeremy Bingham	jbingham@gmail.com
deploy	6a4489d9436ba1541d272700b303410cc906b08f	roles	goiardi_postgres	Create roles table	{goiardi_schema}	{}	{}	2015-07-15 13:18:48.609256-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 12:09:28-07	Jeremy Bingham	jbingham@gmail.com
deploy	c4b32778f2911930f583ce15267aade320ac4dcd	sandboxes	goiardi_postgres	Create sandboxes table	{goiardi_schema}	{}	{}	2015-07-15 13:18:48.63084-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 12:14:48-07	Jeremy Bingham	jbingham@gmail.com
deploy	81003655b93b41359804027fc202788aa0ddd9a9	log_infos	goiardi_postgres	Create log_infos table	{clients,users,goiardi_schema}	{}	{}	2015-07-15 13:18:48.654928-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 12:19:10-07	Jeremy Bingham	jbingham@gmail.com
deploy	fce5b7aeed2ad742de1309d7841577cff19475a7	organizations	goiardi_postgres	Create organizations table	{}	{}	{}	2015-07-15 13:18:48.676462-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 12:46:28-07	Jeremy Bingham	jbingham@gmail.com
deploy	f2621482d1c130ea8fee15d09f966685409bf67c	file_checksums	goiardi_postgres	Create file checksums table	{}	{}	{}	2015-07-15 13:18:48.695512-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 12:49:19-07	Jeremy Bingham	jbingham@gmail.com
deploy	db1eb360cd5e6449a468ceb781d82b45dafb5c2d	reports	goiardi_postgres	Create reports table	{}	{}	{}	2015-07-15 13:18:48.720233-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 13:02:49-07	Jeremy Bingham	jbingham@gmail.com
deploy	c8b38382f7e5a18f36c621327f59205aa8aa9849	client_insert_duplicate	goiardi_postgres	Function to emulate insert ... on duplicate update for clients	{clients,goiardi_schema}	{}	{}	2015-07-15 13:18:48.739966-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 23:00:04-07	Jeremy Bingham	jbingham@gmail.com
deploy	30774a960a0efb6adfbb1d526b8cdb1a45c7d039	client_rename	goiardi_postgres	Function to rename clients	{clients,goiardi_schema}	{}	{}	2015-07-15 13:18:48.756747-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-30 10:22:50-07	Jeremy Bingham	jbingham@gmail.com
deploy	2d1fdc8128b0632e798df7346e76f122ed5915ec	user_insert_duplicate	goiardi_postgres	Function to emulate insert ... on duplicate update for clients	{users,goiardi_schema}	{}	{}	2015-07-15 13:18:48.77332-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-30 13:07:46-07	Jeremy Bingham	jbingham@gmail.com
deploy	f336c149ab32530c9c6ae4408c11558a635f39a1	user_rename	goiardi_postgres	Function to rename users	{users,goiardi_schema}	{}	{}	2015-07-15 13:18:48.788566-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-30 13:15:45-07	Jeremy Bingham	jbingham@gmail.com
deploy	841a7d554d44f9d0d0b8a1a5a9d0a06ce71a2453	cookbook_insert_update	goiardi_postgres	Cookbook insert/update	{cookbooks,goiardi_schema}	{}	{}	2015-07-15 13:18:48.80375-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-30 23:55:23-07	Jeremy Bingham	jbingham@gmail.com
deploy	085e2f6281914c9fa6521d59fea81f16c106b59f	cookbook_versions_insert_update	goiardi_postgres	Cookbook versions insert/update	{cookbook_versions,goiardi_schema}	{}	{}	2015-07-15 13:18:48.820007-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-30 23:56:05-07	Jeremy Bingham	jbingham@gmail.com
deploy	04bea39d649e4187d9579bd946fd60f760240d10	data_bag_insert_update	goiardi_postgres	Insert/update data bags	{data_bags,goiardi_schema}	{}	{}	2015-07-15 13:18:48.835017-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-31 23:25:44-07	Jeremy Bingham	jbingham@gmail.com
deploy	092885e8b5d94a9c1834bf309e02dc0f955ff053	environment_insert_update	goiardi_postgres	Insert/update environments	{environments,goiardi_schema}	{}	{}	2015-07-15 13:18:48.850119-07	Jeremy Bingham	jeremy@goiardi.gl	2014-06-01 12:55:34-07	Jeremy Bingham	jbingham@gmail.com
deploy	6d9587fa4275827c93ca9d7e0166ad1887b76cad	file_checksum_insert_ignore	goiardi_postgres	Insert ignore for file checksums	{file_checksums,goiardi_schema}	{}	{}	2015-07-15 13:18:48.865805-07	Jeremy Bingham	jeremy@goiardi.gl	2014-06-01 23:13:48-07	Jeremy Bingham	jbingham@gmail.com
deploy	82a95e5e6cbd8ba51fea33506e1edb2a12e37a92	node_insert_update	goiardi_postgres	Insert/update for nodes	{nodes,goiardi_schema}	{}	{}	2015-07-15 13:18:48.881349-07	Jeremy Bingham	jeremy@goiardi.gl	2014-06-01 23:25:20-07	Jeremy Bingham	jbingham@gmail.com
deploy	d052a8267a6512581e5cab1f89a2456f279727b9	report_insert_update	goiardi_postgres	Insert/update for reports	{reports,goiardi_schema}	{}	{}	2015-07-15 13:18:48.896767-07	Jeremy Bingham	jeremy@goiardi.gl	2014-06-02 10:10:25-07	Jeremy Bingham	jbingham@gmail.com
deploy	acf76029633d50febbec7c4763b7173078eddaf7	role_insert_update	goiardi_postgres	Insert/update for roles	{roles,goiardi_schema}	{}	{}	2015-07-15 13:18:48.915081-07	Jeremy Bingham	jeremy@goiardi.gl	2014-06-02 10:27:32-07	Jeremy Bingham	jbingham@gmail.com
deploy	b8ef36df686397ecb0fe67eb097e84aa0d78ac6b	sandbox_insert_update	goiardi_postgres	Insert/update for sandboxes	{sandboxes,goiardi_schema}	{}	{}	2015-07-15 13:18:48.930353-07	Jeremy Bingham	jeremy@goiardi.gl	2014-06-02 10:34:39-07	Jeremy Bingham	jbingham@gmail.com
deploy	93dbbda50a25da0a586e89ccee8fcfa2ddcb7c64	data_bag_item_insert	goiardi_postgres	Insert for data bag items	{data_bag_items,data_bags,goiardi_schema}	{}	{@v0.6.0}	2015-07-15 13:18:48.946805-07	Jeremy Bingham	jeremy@goiardi.gl	2014-06-02 14:03:22-07	Jeremy Bingham	jbingham@gmail.com
deploy	c80c561c22f6e139165cdb338c7ce6fff8ff268d	bytea_to_json	goiardi_postgres	Change most postgres bytea fields to json, because in this peculiar case json is way faster than gob	{}	{}	{}	2015-07-15 13:18:49.007323-07	Jeremy Bingham	jeremy@goiardi.gl	2014-07-20 02:41:22-07	Jeremy Bingham	jbingham@gmail.com
deploy	9966894e0fc0da573243f6a3c0fc1432a2b63043	joined_cookbkook_version	goiardi_postgres	a convenient view for joined versions for cookbook versions, adapted from erchef's joined_cookbook_version	{}	{}	{@v0.7.0}	2015-07-15 13:18:49.033222-07	Jeremy Bingham	jeremy@goiardi.gl	2014-07-20 03:21:28-07	Jeremy Bingham	jbingham@gmail.com
deploy	163ba4a496b9b4210d335e0e4ea5368a9ea8626c	node_statuses	goiardi_postgres	Create node_status table for node statuses	{nodes}	{}	{}	2015-07-15 13:18:49.053081-07	Jeremy Bingham	jeremy@goiardi.gl	2014-07-10 23:01:54-07	Jeremy Bingham	jeremy@terqa.local
deploy	8bb822f391b499585cfb2fc7248be469b0200682	node_status_insert	goiardi_postgres	insert function for node_statuses	{node_statuses}	{}	{}	2015-07-15 13:18:49.068154-07	Jeremy Bingham	jeremy@goiardi.gl	2014-07-11 00:01:31-07	Jeremy Bingham	jeremy@terqa.local
deploy	7c429aac08527adc774767584201f668408b04a6	add_down_column_nodes	goiardi_postgres	Add is_down column to the nodes table	{nodes}	{}	{}	2015-07-15 13:18:49.091453-07	Jeremy Bingham	jeremy@goiardi.gl	2014-07-15 20:18:05-07	Jeremy Bingham	jbingham@gmail.com
deploy	82bcace325dbdc905eb6e677f800d14a0506a216	shovey	goiardi_postgres	add shovey tables	{}	{}	{}	2015-07-15 13:18:49.129972-07	Jeremy Bingham	jeremy@goiardi.gl	2014-07-15 22:07:12-07	Jeremy Bingham	jeremy@terqa.local
deploy	62046d2fb96bbaedce2406252d312766452551c0	node_latest_statuses	goiardi_postgres	Add a view to easily get nodes by their latest status	{node_statuses}	{}	{}	2015-07-15 13:18:49.153233-07	Jeremy Bingham	jeremy@goiardi.gl	2014-07-26 13:32:02-07	Jeremy Bingham	jbingham@gmail.com
deploy	68f90e1fd2aac6a117d7697626741a02b8d0ebbe	shovey_insert_update	goiardi_postgres	insert/update functions for shovey	{shovey}	{}	{@v0.8.0}	2015-07-15 13:18:49.171593-07	Jeremy Bingham	jeremy@goiardi.gl	2014-08-27 00:46:20-07	Jeremy Bingham	jbingham@gmail.com
deploy	6f7aa2430e01cf33715828f1957d072cd5006d1c	ltree	goiardi_postgres	Add tables for ltree search for postgres	{}	{}	{}	2015-07-15 13:18:49.240195-07	Jeremy Bingham	jeremy@goiardi.gl	2015-04-10 23:21:26-07	Jeremy Bingham	jeremy@goiardi.gl
deploy	e7eb33b00d2fb6302e0c3979e9cac6fb80da377e	ltree_del_col	goiardi_postgres	procedure for deleting search collections	{}	{}	{}	2015-07-15 13:18:49.255451-07	Jeremy Bingham	jeremy@goiardi.gl	2015-04-12 12:33:15-07	Jeremy Bingham	jeremy@goiardi.gl
deploy	f49decbb15053ec5691093568450f642578ca460	ltree_del_item	goiardi_postgres	procedure for deleting search items	{}	{}	{}	2015-07-15 13:18:49.270058-07	Jeremy Bingham	jeremy@goiardi.gl	2015-04-12 13:03:50-07	Jeremy Bingham	jeremy@goiardi.gl
revert	f49decbb15053ec5691093568450f642578ca460	ltree_del_item	goiardi_postgres	procedure for deleting search items	{}	{}	{}	2015-07-15 14:04:47.265898-07	Jeremy Bingham	jeremy@goiardi.gl	2015-04-12 13:03:50-07	Jeremy Bingham	jeremy@goiardi.gl
revert	e7eb33b00d2fb6302e0c3979e9cac6fb80da377e	ltree_del_col	goiardi_postgres	procedure for deleting search collections	{}	{}	{}	2015-07-15 14:04:47.280614-07	Jeremy Bingham	jeremy@goiardi.gl	2015-04-12 12:33:15-07	Jeremy Bingham	jeremy@goiardi.gl
revert	6f7aa2430e01cf33715828f1957d072cd5006d1c	ltree	goiardi_postgres	Add tables for ltree search for postgres	{}	{}	{}	2015-07-15 14:04:47.311566-07	Jeremy Bingham	jeremy@goiardi.gl	2015-04-10 23:21:26-07	Jeremy Bingham	jeremy@goiardi.gl
revert	68f90e1fd2aac6a117d7697626741a02b8d0ebbe	shovey_insert_update	goiardi_postgres	insert/update functions for shovey	{shovey}	{}	{@v0.8.0}	2015-07-15 14:04:47.325145-07	Jeremy Bingham	jeremy@goiardi.gl	2014-08-27 00:46:20-07	Jeremy Bingham	jbingham@gmail.com
revert	62046d2fb96bbaedce2406252d312766452551c0	node_latest_statuses	goiardi_postgres	Add a view to easily get nodes by their latest status	{node_statuses}	{}	{}	2015-07-15 14:04:47.339765-07	Jeremy Bingham	jeremy@goiardi.gl	2014-07-26 13:32:02-07	Jeremy Bingham	jbingham@gmail.com
revert	82bcace325dbdc905eb6e677f800d14a0506a216	shovey	goiardi_postgres	add shovey tables	{}	{}	{}	2015-07-15 14:04:47.363011-07	Jeremy Bingham	jeremy@goiardi.gl	2014-07-15 22:07:12-07	Jeremy Bingham	jeremy@terqa.local
revert	7c429aac08527adc774767584201f668408b04a6	add_down_column_nodes	goiardi_postgres	Add is_down column to the nodes table	{nodes}	{}	{}	2015-07-15 14:04:47.380023-07	Jeremy Bingham	jeremy@goiardi.gl	2014-07-15 20:18:05-07	Jeremy Bingham	jbingham@gmail.com
revert	8bb822f391b499585cfb2fc7248be469b0200682	node_status_insert	goiardi_postgres	insert function for node_statuses	{node_statuses}	{}	{}	2015-07-15 14:04:47.393783-07	Jeremy Bingham	jeremy@goiardi.gl	2014-07-11 00:01:31-07	Jeremy Bingham	jeremy@terqa.local
revert	163ba4a496b9b4210d335e0e4ea5368a9ea8626c	node_statuses	goiardi_postgres	Create node_status table for node statuses	{nodes}	{}	{}	2015-07-15 14:04:47.411758-07	Jeremy Bingham	jeremy@goiardi.gl	2014-07-10 23:01:54-07	Jeremy Bingham	jeremy@terqa.local
revert	9966894e0fc0da573243f6a3c0fc1432a2b63043	joined_cookbkook_version	goiardi_postgres	a convenient view for joined versions for cookbook versions, adapted from erchef's joined_cookbook_version	{}	{}	{@v0.7.0}	2015-07-15 14:04:47.426028-07	Jeremy Bingham	jeremy@goiardi.gl	2014-07-20 03:21:28-07	Jeremy Bingham	jbingham@gmail.com
revert	c80c561c22f6e139165cdb338c7ce6fff8ff268d	bytea_to_json	goiardi_postgres	Change most postgres bytea fields to json, because in this peculiar case json is way faster than gob	{}	{}	{}	2015-07-15 14:04:47.49685-07	Jeremy Bingham	jeremy@goiardi.gl	2014-07-20 02:41:22-07	Jeremy Bingham	jbingham@gmail.com
revert	93dbbda50a25da0a586e89ccee8fcfa2ddcb7c64	data_bag_item_insert	goiardi_postgres	Insert for data bag items	{data_bag_items,data_bags,goiardi_schema}	{}	{@v0.6.0}	2015-07-15 14:04:47.512095-07	Jeremy Bingham	jeremy@goiardi.gl	2014-06-02 14:03:22-07	Jeremy Bingham	jbingham@gmail.com
revert	b8ef36df686397ecb0fe67eb097e84aa0d78ac6b	sandbox_insert_update	goiardi_postgres	Insert/update for sandboxes	{sandboxes,goiardi_schema}	{}	{}	2015-07-15 14:04:47.526063-07	Jeremy Bingham	jeremy@goiardi.gl	2014-06-02 10:34:39-07	Jeremy Bingham	jbingham@gmail.com
revert	acf76029633d50febbec7c4763b7173078eddaf7	role_insert_update	goiardi_postgres	Insert/update for roles	{roles,goiardi_schema}	{}	{}	2015-07-15 14:04:47.540768-07	Jeremy Bingham	jeremy@goiardi.gl	2014-06-02 10:27:32-07	Jeremy Bingham	jbingham@gmail.com
revert	d052a8267a6512581e5cab1f89a2456f279727b9	report_insert_update	goiardi_postgres	Insert/update for reports	{reports,goiardi_schema}	{}	{}	2015-07-15 14:04:47.555027-07	Jeremy Bingham	jeremy@goiardi.gl	2014-06-02 10:10:25-07	Jeremy Bingham	jbingham@gmail.com
revert	82a95e5e6cbd8ba51fea33506e1edb2a12e37a92	node_insert_update	goiardi_postgres	Insert/update for nodes	{nodes,goiardi_schema}	{}	{}	2015-07-15 14:04:47.567717-07	Jeremy Bingham	jeremy@goiardi.gl	2014-06-01 23:25:20-07	Jeremy Bingham	jbingham@gmail.com
revert	6d9587fa4275827c93ca9d7e0166ad1887b76cad	file_checksum_insert_ignore	goiardi_postgres	Insert ignore for file checksums	{file_checksums,goiardi_schema}	{}	{}	2015-07-15 14:04:47.582545-07	Jeremy Bingham	jeremy@goiardi.gl	2014-06-01 23:13:48-07	Jeremy Bingham	jbingham@gmail.com
revert	092885e8b5d94a9c1834bf309e02dc0f955ff053	environment_insert_update	goiardi_postgres	Insert/update environments	{environments,goiardi_schema}	{}	{}	2015-07-15 14:04:47.597498-07	Jeremy Bingham	jeremy@goiardi.gl	2014-06-01 12:55:34-07	Jeremy Bingham	jbingham@gmail.com
revert	04bea39d649e4187d9579bd946fd60f760240d10	data_bag_insert_update	goiardi_postgres	Insert/update data bags	{data_bags,goiardi_schema}	{}	{}	2015-07-15 14:04:47.612144-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-31 23:25:44-07	Jeremy Bingham	jbingham@gmail.com
revert	085e2f6281914c9fa6521d59fea81f16c106b59f	cookbook_versions_insert_update	goiardi_postgres	Cookbook versions insert/update	{cookbook_versions,goiardi_schema}	{}	{}	2015-07-15 14:04:47.626606-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-30 23:56:05-07	Jeremy Bingham	jbingham@gmail.com
revert	841a7d554d44f9d0d0b8a1a5a9d0a06ce71a2453	cookbook_insert_update	goiardi_postgres	Cookbook insert/update	{cookbooks,goiardi_schema}	{}	{}	2015-07-15 14:04:47.640536-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-30 23:55:23-07	Jeremy Bingham	jbingham@gmail.com
revert	f336c149ab32530c9c6ae4408c11558a635f39a1	user_rename	goiardi_postgres	Function to rename users	{users,goiardi_schema}	{}	{}	2015-07-15 14:04:47.65676-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-30 13:15:45-07	Jeremy Bingham	jbingham@gmail.com
revert	2d1fdc8128b0632e798df7346e76f122ed5915ec	user_insert_duplicate	goiardi_postgres	Function to emulate insert ... on duplicate update for clients	{users,goiardi_schema}	{}	{}	2015-07-15 14:04:47.670447-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-30 13:07:46-07	Jeremy Bingham	jbingham@gmail.com
revert	30774a960a0efb6adfbb1d526b8cdb1a45c7d039	client_rename	goiardi_postgres	Function to rename clients	{clients,goiardi_schema}	{}	{}	2015-07-15 14:04:47.684701-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-30 10:22:50-07	Jeremy Bingham	jbingham@gmail.com
revert	c8b38382f7e5a18f36c621327f59205aa8aa9849	client_insert_duplicate	goiardi_postgres	Function to emulate insert ... on duplicate update for clients	{clients,goiardi_schema}	{}	{}	2015-07-15 14:04:47.699301-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 23:00:04-07	Jeremy Bingham	jbingham@gmail.com
revert	db1eb360cd5e6449a468ceb781d82b45dafb5c2d	reports	goiardi_postgres	Create reports table	{}	{}	{}	2015-07-15 14:04:47.717362-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 13:02:49-07	Jeremy Bingham	jbingham@gmail.com
revert	f2621482d1c130ea8fee15d09f966685409bf67c	file_checksums	goiardi_postgres	Create file checksums table	{}	{}	{}	2015-07-15 14:04:47.73526-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 12:49:19-07	Jeremy Bingham	jbingham@gmail.com
revert	fce5b7aeed2ad742de1309d7841577cff19475a7	organizations	goiardi_postgres	Create organizations table	{}	{}	{}	2015-07-15 14:04:47.751929-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 12:46:28-07	Jeremy Bingham	jbingham@gmail.com
revert	81003655b93b41359804027fc202788aa0ddd9a9	log_infos	goiardi_postgres	Create log_infos table	{clients,users,goiardi_schema}	{}	{}	2015-07-15 14:04:47.772742-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 12:19:10-07	Jeremy Bingham	jbingham@gmail.com
revert	c4b32778f2911930f583ce15267aade320ac4dcd	sandboxes	goiardi_postgres	Create sandboxes table	{goiardi_schema}	{}	{}	2015-07-15 14:04:47.791299-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 12:14:48-07	Jeremy Bingham	jbingham@gmail.com
revert	6a4489d9436ba1541d272700b303410cc906b08f	roles	goiardi_postgres	Create roles table	{goiardi_schema}	{}	{}	2015-07-15 14:04:47.810177-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 12:09:28-07	Jeremy Bingham	jbingham@gmail.com
revert	feddf91b62caed36c790988bd29222591980433b	data_bag_items	goiardi_postgres	Create data bag items table	{data_bags,goiardi_schema}	{}	{}	2015-07-15 14:04:47.827441-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 12:02:31-07	Jeremy Bingham	jbingham@gmail.com
revert	85483913f96710c1267c6abacb6568cef9327f15	data_bags	goiardi_postgres	Create cookbook data bags table	{goiardi_schema}	{}	{}	2015-07-15 14:04:47.845855-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 11:42:04-07	Jeremy Bingham	jbingham@gmail.com
revert	f529038064a0259bdecbdab1f9f665e17ddb6136	cookbook_versions	goiardi_postgres	Create cookbook versions table	{cookbooks,goiardi_schema}	{}	{}	2015-07-15 14:04:47.863423-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 11:31:34-07	Jeremy Bingham	jbingham@gmail.com
revert	138bc49d92c0bbb024cea41532a656f2d7f9b072	cookbooks	goiardi_postgres	Create cookbook  table	{goiardi_schema}	{}	{}	2015-07-15 14:04:47.881778-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 11:27:27-07	Jeremy Bingham	jbingham@gmail.com
revert	bb82d8869ffca8ba3d03a1502c50dbb3eee7a2e0	users	goiardi_postgres	Create user table	{goiardi_schema}	{}	{}	2015-07-15 14:04:47.90223-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 11:15:02-07	Jeremy Bingham	jbingham@gmail.com
revert	faa3571aa479de60f25785e707433b304ba3d2c7	clients	goiardi_postgres	Create client table	{goiardi_schema}	{}	{}	2015-07-15 14:04:47.919836-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 11:05:33-07	Jeremy Bingham	jbingham@gmail.com
revert	911c456769628c817340ee77fc8d2b7c1d697782	nodes	goiardi_postgres	Create node table	{goiardi_schema}	{}	{}	2015-07-15 14:04:47.938191-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 10:37:46-07	Jeremy Bingham	jbingham@gmail.com
revert	367c28670efddf25455b9fd33c23a5a278b08bb4	environments	goiardi_postgres	Environments for postgres	{goiardi_schema}	{}	{}	2015-07-15 14:04:47.955879-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 00:40:11-07	Jeremy Bingham	jbingham@gmail.com
revert	c89b0e25c808b327036c88e6c9750c7526314c86	goiardi_schema	goiardi_postgres	Add schema for goiardi-postgres	{}	{}	{}	2015-07-15 14:04:47.970356-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-27 14:09:07-07	Jeremy Bingham	jbingham@gmail.com
deploy	c89b0e25c808b327036c88e6c9750c7526314c86	goiardi_schema	goiardi_postgres	Add schema for goiardi-postgres	{}	{}	{}	2015-07-15 14:04:49.650581-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-27 14:09:07-07	Jeremy Bingham	jbingham@gmail.com
deploy	367c28670efddf25455b9fd33c23a5a278b08bb4	environments	goiardi_postgres	Environments for postgres	{goiardi_schema}	{}	{}	2015-07-15 14:04:49.68419-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 00:40:11-07	Jeremy Bingham	jbingham@gmail.com
deploy	911c456769628c817340ee77fc8d2b7c1d697782	nodes	goiardi_postgres	Create node table	{goiardi_schema}	{}	{}	2015-07-15 14:04:49.709062-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 10:37:46-07	Jeremy Bingham	jbingham@gmail.com
deploy	faa3571aa479de60f25785e707433b304ba3d2c7	clients	goiardi_postgres	Create client table	{goiardi_schema}	{}	{}	2015-07-15 14:04:49.734007-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 11:05:33-07	Jeremy Bingham	jbingham@gmail.com
deploy	bb82d8869ffca8ba3d03a1502c50dbb3eee7a2e0	users	goiardi_postgres	Create user table	{goiardi_schema}	{}	{}	2015-07-15 14:04:49.756403-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 11:15:02-07	Jeremy Bingham	jbingham@gmail.com
deploy	138bc49d92c0bbb024cea41532a656f2d7f9b072	cookbooks	goiardi_postgres	Create cookbook  table	{goiardi_schema}	{}	{}	2015-07-15 14:04:49.779889-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 11:27:27-07	Jeremy Bingham	jbingham@gmail.com
deploy	f529038064a0259bdecbdab1f9f665e17ddb6136	cookbook_versions	goiardi_postgres	Create cookbook versions table	{cookbooks,goiardi_schema}	{}	{}	2015-07-15 14:04:49.805201-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 11:31:34-07	Jeremy Bingham	jbingham@gmail.com
deploy	85483913f96710c1267c6abacb6568cef9327f15	data_bags	goiardi_postgres	Create cookbook data bags table	{goiardi_schema}	{}	{}	2015-07-15 14:04:49.826138-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 11:42:04-07	Jeremy Bingham	jbingham@gmail.com
deploy	feddf91b62caed36c790988bd29222591980433b	data_bag_items	goiardi_postgres	Create data bag items table	{data_bags,goiardi_schema}	{}	{}	2015-07-15 14:04:49.849268-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 12:02:31-07	Jeremy Bingham	jbingham@gmail.com
deploy	6a4489d9436ba1541d272700b303410cc906b08f	roles	goiardi_postgres	Create roles table	{goiardi_schema}	{}	{}	2015-07-15 14:04:49.872757-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 12:09:28-07	Jeremy Bingham	jbingham@gmail.com
deploy	c4b32778f2911930f583ce15267aade320ac4dcd	sandboxes	goiardi_postgres	Create sandboxes table	{goiardi_schema}	{}	{}	2015-07-15 14:04:49.897441-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 12:14:48-07	Jeremy Bingham	jbingham@gmail.com
deploy	81003655b93b41359804027fc202788aa0ddd9a9	log_infos	goiardi_postgres	Create log_infos table	{clients,users,goiardi_schema}	{}	{}	2015-07-15 14:04:49.927579-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 12:19:10-07	Jeremy Bingham	jbingham@gmail.com
deploy	fce5b7aeed2ad742de1309d7841577cff19475a7	organizations	goiardi_postgres	Create organizations table	{}	{}	{}	2015-07-15 14:04:49.952712-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 12:46:28-07	Jeremy Bingham	jbingham@gmail.com
deploy	f2621482d1c130ea8fee15d09f966685409bf67c	file_checksums	goiardi_postgres	Create file checksums table	{}	{}	{}	2015-07-15 14:04:49.972168-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 12:49:19-07	Jeremy Bingham	jbingham@gmail.com
deploy	db1eb360cd5e6449a468ceb781d82b45dafb5c2d	reports	goiardi_postgres	Create reports table	{}	{}	{}	2015-07-15 14:04:49.999476-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 13:02:49-07	Jeremy Bingham	jbingham@gmail.com
deploy	c8b38382f7e5a18f36c621327f59205aa8aa9849	client_insert_duplicate	goiardi_postgres	Function to emulate insert ... on duplicate update for clients	{clients,goiardi_schema}	{}	{}	2015-07-15 14:04:50.016046-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 23:00:04-07	Jeremy Bingham	jbingham@gmail.com
deploy	30774a960a0efb6adfbb1d526b8cdb1a45c7d039	client_rename	goiardi_postgres	Function to rename clients	{clients,goiardi_schema}	{}	{}	2015-07-15 14:04:50.03218-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-30 10:22:50-07	Jeremy Bingham	jbingham@gmail.com
deploy	2d1fdc8128b0632e798df7346e76f122ed5915ec	user_insert_duplicate	goiardi_postgres	Function to emulate insert ... on duplicate update for clients	{users,goiardi_schema}	{}	{}	2015-07-15 14:04:50.047963-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-30 13:07:46-07	Jeremy Bingham	jbingham@gmail.com
deploy	f336c149ab32530c9c6ae4408c11558a635f39a1	user_rename	goiardi_postgres	Function to rename users	{users,goiardi_schema}	{}	{}	2015-07-15 14:04:50.064335-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-30 13:15:45-07	Jeremy Bingham	jbingham@gmail.com
deploy	841a7d554d44f9d0d0b8a1a5a9d0a06ce71a2453	cookbook_insert_update	goiardi_postgres	Cookbook insert/update	{cookbooks,goiardi_schema}	{}	{}	2015-07-15 14:04:50.079041-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-30 23:55:23-07	Jeremy Bingham	jbingham@gmail.com
deploy	085e2f6281914c9fa6521d59fea81f16c106b59f	cookbook_versions_insert_update	goiardi_postgres	Cookbook versions insert/update	{cookbook_versions,goiardi_schema}	{}	{}	2015-07-15 14:04:50.095061-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-30 23:56:05-07	Jeremy Bingham	jbingham@gmail.com
deploy	04bea39d649e4187d9579bd946fd60f760240d10	data_bag_insert_update	goiardi_postgres	Insert/update data bags	{data_bags,goiardi_schema}	{}	{}	2015-07-15 14:04:50.111691-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-31 23:25:44-07	Jeremy Bingham	jbingham@gmail.com
deploy	092885e8b5d94a9c1834bf309e02dc0f955ff053	environment_insert_update	goiardi_postgres	Insert/update environments	{environments,goiardi_schema}	{}	{}	2015-07-15 14:04:50.130491-07	Jeremy Bingham	jeremy@goiardi.gl	2014-06-01 12:55:34-07	Jeremy Bingham	jbingham@gmail.com
deploy	6d9587fa4275827c93ca9d7e0166ad1887b76cad	file_checksum_insert_ignore	goiardi_postgres	Insert ignore for file checksums	{file_checksums,goiardi_schema}	{}	{}	2015-07-15 14:04:50.149417-07	Jeremy Bingham	jeremy@goiardi.gl	2014-06-01 23:13:48-07	Jeremy Bingham	jbingham@gmail.com
deploy	82a95e5e6cbd8ba51fea33506e1edb2a12e37a92	node_insert_update	goiardi_postgres	Insert/update for nodes	{nodes,goiardi_schema}	{}	{}	2015-07-15 14:04:50.165024-07	Jeremy Bingham	jeremy@goiardi.gl	2014-06-01 23:25:20-07	Jeremy Bingham	jbingham@gmail.com
deploy	d052a8267a6512581e5cab1f89a2456f279727b9	report_insert_update	goiardi_postgres	Insert/update for reports	{reports,goiardi_schema}	{}	{}	2015-07-15 14:04:50.181058-07	Jeremy Bingham	jeremy@goiardi.gl	2014-06-02 10:10:25-07	Jeremy Bingham	jbingham@gmail.com
deploy	acf76029633d50febbec7c4763b7173078eddaf7	role_insert_update	goiardi_postgres	Insert/update for roles	{roles,goiardi_schema}	{}	{}	2015-07-15 14:04:50.196353-07	Jeremy Bingham	jeremy@goiardi.gl	2014-06-02 10:27:32-07	Jeremy Bingham	jbingham@gmail.com
deploy	b8ef36df686397ecb0fe67eb097e84aa0d78ac6b	sandbox_insert_update	goiardi_postgres	Insert/update for sandboxes	{sandboxes,goiardi_schema}	{}	{}	2015-07-15 14:04:50.211504-07	Jeremy Bingham	jeremy@goiardi.gl	2014-06-02 10:34:39-07	Jeremy Bingham	jbingham@gmail.com
deploy	93dbbda50a25da0a586e89ccee8fcfa2ddcb7c64	data_bag_item_insert	goiardi_postgres	Insert for data bag items	{data_bag_items,data_bags,goiardi_schema}	{}	{@v0.6.0}	2015-07-15 14:04:50.228498-07	Jeremy Bingham	jeremy@goiardi.gl	2014-06-02 14:03:22-07	Jeremy Bingham	jbingham@gmail.com
deploy	c80c561c22f6e139165cdb338c7ce6fff8ff268d	bytea_to_json	goiardi_postgres	Change most postgres bytea fields to json, because in this peculiar case json is way faster than gob	{}	{}	{}	2015-07-15 14:04:50.318047-07	Jeremy Bingham	jeremy@goiardi.gl	2014-07-20 02:41:22-07	Jeremy Bingham	jbingham@gmail.com
deploy	9966894e0fc0da573243f6a3c0fc1432a2b63043	joined_cookbkook_version	goiardi_postgres	a convenient view for joined versions for cookbook versions, adapted from erchef's joined_cookbook_version	{}	{}	{@v0.7.0}	2015-07-15 14:04:50.337077-07	Jeremy Bingham	jeremy@goiardi.gl	2014-07-20 03:21:28-07	Jeremy Bingham	jbingham@gmail.com
deploy	163ba4a496b9b4210d335e0e4ea5368a9ea8626c	node_statuses	goiardi_postgres	Create node_status table for node statuses	{nodes}	{}	{}	2015-07-15 14:04:50.362969-07	Jeremy Bingham	jeremy@goiardi.gl	2014-07-10 23:01:54-07	Jeremy Bingham	jeremy@terqa.local
deploy	8bb822f391b499585cfb2fc7248be469b0200682	node_status_insert	goiardi_postgres	insert function for node_statuses	{node_statuses}	{}	{}	2015-07-15 14:04:50.377716-07	Jeremy Bingham	jeremy@goiardi.gl	2014-07-11 00:01:31-07	Jeremy Bingham	jeremy@terqa.local
deploy	7c429aac08527adc774767584201f668408b04a6	add_down_column_nodes	goiardi_postgres	Add is_down column to the nodes table	{nodes}	{}	{}	2015-07-15 14:04:50.405753-07	Jeremy Bingham	jeremy@goiardi.gl	2014-07-15 20:18:05-07	Jeremy Bingham	jbingham@gmail.com
deploy	82bcace325dbdc905eb6e677f800d14a0506a216	shovey	goiardi_postgres	add shovey tables	{}	{}	{}	2015-07-15 14:04:50.455353-07	Jeremy Bingham	jeremy@goiardi.gl	2014-07-15 22:07:12-07	Jeremy Bingham	jeremy@terqa.local
deploy	62046d2fb96bbaedce2406252d312766452551c0	node_latest_statuses	goiardi_postgres	Add a view to easily get nodes by their latest status	{node_statuses}	{}	{}	2015-07-15 14:04:50.473171-07	Jeremy Bingham	jeremy@goiardi.gl	2014-07-26 13:32:02-07	Jeremy Bingham	jbingham@gmail.com
deploy	68f90e1fd2aac6a117d7697626741a02b8d0ebbe	shovey_insert_update	goiardi_postgres	insert/update functions for shovey	{shovey}	{}	{@v0.8.0}	2015-07-15 14:04:50.491423-07	Jeremy Bingham	jeremy@goiardi.gl	2014-08-27 00:46:20-07	Jeremy Bingham	jbingham@gmail.com
deploy	6f7aa2430e01cf33715828f1957d072cd5006d1c	ltree	goiardi_postgres	Add tables for ltree search for postgres	{}	{}	{}	2015-07-15 14:04:50.56-07	Jeremy Bingham	jeremy@goiardi.gl	2015-04-10 23:21:26-07	Jeremy Bingham	jeremy@goiardi.gl
deploy	e7eb33b00d2fb6302e0c3979e9cac6fb80da377e	ltree_del_col	goiardi_postgres	procedure for deleting search collections	{}	{}	{}	2015-07-15 14:04:50.574957-07	Jeremy Bingham	jeremy@goiardi.gl	2015-04-12 12:33:15-07	Jeremy Bingham	jeremy@goiardi.gl
deploy	f49decbb15053ec5691093568450f642578ca460	ltree_del_item	goiardi_postgres	procedure for deleting search items	{}	{}	{}	2015-07-15 14:04:50.591088-07	Jeremy Bingham	jeremy@goiardi.gl	2015-04-12 13:03:50-07	Jeremy Bingham	jeremy@goiardi.gl
revert	f49decbb15053ec5691093568450f642578ca460	ltree_del_item	goiardi_postgres	procedure for deleting search items	{}	{}	{}	2015-07-15 15:25:26.129509-07	Jeremy Bingham	jeremy@goiardi.gl	2015-04-12 13:03:50-07	Jeremy Bingham	jeremy@goiardi.gl
revert	e7eb33b00d2fb6302e0c3979e9cac6fb80da377e	ltree_del_col	goiardi_postgres	procedure for deleting search collections	{}	{}	{}	2015-07-15 15:25:26.144746-07	Jeremy Bingham	jeremy@goiardi.gl	2015-04-12 12:33:15-07	Jeremy Bingham	jeremy@goiardi.gl
revert	6f7aa2430e01cf33715828f1957d072cd5006d1c	ltree	goiardi_postgres	Add tables for ltree search for postgres	{}	{}	{}	2015-07-15 15:25:26.226039-07	Jeremy Bingham	jeremy@goiardi.gl	2015-04-10 23:21:26-07	Jeremy Bingham	jeremy@goiardi.gl
revert	68f90e1fd2aac6a117d7697626741a02b8d0ebbe	shovey_insert_update	goiardi_postgres	insert/update functions for shovey	{shovey}	{}	{@v0.8.0}	2015-07-15 15:25:26.241061-07	Jeremy Bingham	jeremy@goiardi.gl	2014-08-27 00:46:20-07	Jeremy Bingham	jbingham@gmail.com
revert	62046d2fb96bbaedce2406252d312766452551c0	node_latest_statuses	goiardi_postgres	Add a view to easily get nodes by their latest status	{node_statuses}	{}	{}	2015-07-15 15:25:26.25535-07	Jeremy Bingham	jeremy@goiardi.gl	2014-07-26 13:32:02-07	Jeremy Bingham	jbingham@gmail.com
revert	82bcace325dbdc905eb6e677f800d14a0506a216	shovey	goiardi_postgres	add shovey tables	{}	{}	{}	2015-07-15 15:25:26.304506-07	Jeremy Bingham	jeremy@goiardi.gl	2014-07-15 22:07:12-07	Jeremy Bingham	jeremy@terqa.local
revert	7c429aac08527adc774767584201f668408b04a6	add_down_column_nodes	goiardi_postgres	Add is_down column to the nodes table	{nodes}	{}	{}	2015-07-15 15:25:26.322934-07	Jeremy Bingham	jeremy@goiardi.gl	2014-07-15 20:18:05-07	Jeremy Bingham	jbingham@gmail.com
revert	8bb822f391b499585cfb2fc7248be469b0200682	node_status_insert	goiardi_postgres	insert function for node_statuses	{node_statuses}	{}	{}	2015-07-15 15:25:26.337137-07	Jeremy Bingham	jeremy@goiardi.gl	2014-07-11 00:01:31-07	Jeremy Bingham	jeremy@terqa.local
revert	163ba4a496b9b4210d335e0e4ea5368a9ea8626c	node_statuses	goiardi_postgres	Create node_status table for node statuses	{nodes}	{}	{}	2015-07-15 15:25:26.360973-07	Jeremy Bingham	jeremy@goiardi.gl	2014-07-10 23:01:54-07	Jeremy Bingham	jeremy@terqa.local
revert	9966894e0fc0da573243f6a3c0fc1432a2b63043	joined_cookbkook_version	goiardi_postgres	a convenient view for joined versions for cookbook versions, adapted from erchef's joined_cookbook_version	{}	{}	{@v0.7.0}	2015-07-15 15:25:26.376523-07	Jeremy Bingham	jeremy@goiardi.gl	2014-07-20 03:21:28-07	Jeremy Bingham	jbingham@gmail.com
revert	c80c561c22f6e139165cdb338c7ce6fff8ff268d	bytea_to_json	goiardi_postgres	Change most postgres bytea fields to json, because in this peculiar case json is way faster than gob	{}	{}	{}	2015-07-15 15:25:26.500252-07	Jeremy Bingham	jeremy@goiardi.gl	2014-07-20 02:41:22-07	Jeremy Bingham	jbingham@gmail.com
revert	93dbbda50a25da0a586e89ccee8fcfa2ddcb7c64	data_bag_item_insert	goiardi_postgres	Insert for data bag items	{data_bag_items,data_bags,goiardi_schema}	{}	{@v0.6.0}	2015-07-15 15:25:26.513636-07	Jeremy Bingham	jeremy@goiardi.gl	2014-06-02 14:03:22-07	Jeremy Bingham	jbingham@gmail.com
revert	b8ef36df686397ecb0fe67eb097e84aa0d78ac6b	sandbox_insert_update	goiardi_postgres	Insert/update for sandboxes	{sandboxes,goiardi_schema}	{}	{}	2015-07-15 15:25:26.527739-07	Jeremy Bingham	jeremy@goiardi.gl	2014-06-02 10:34:39-07	Jeremy Bingham	jbingham@gmail.com
revert	acf76029633d50febbec7c4763b7173078eddaf7	role_insert_update	goiardi_postgres	Insert/update for roles	{roles,goiardi_schema}	{}	{}	2015-07-15 15:25:26.541891-07	Jeremy Bingham	jeremy@goiardi.gl	2014-06-02 10:27:32-07	Jeremy Bingham	jbingham@gmail.com
revert	d052a8267a6512581e5cab1f89a2456f279727b9	report_insert_update	goiardi_postgres	Insert/update for reports	{reports,goiardi_schema}	{}	{}	2015-07-15 15:25:26.554656-07	Jeremy Bingham	jeremy@goiardi.gl	2014-06-02 10:10:25-07	Jeremy Bingham	jbingham@gmail.com
revert	82a95e5e6cbd8ba51fea33506e1edb2a12e37a92	node_insert_update	goiardi_postgres	Insert/update for nodes	{nodes,goiardi_schema}	{}	{}	2015-07-15 15:25:26.568304-07	Jeremy Bingham	jeremy@goiardi.gl	2014-06-01 23:25:20-07	Jeremy Bingham	jbingham@gmail.com
revert	6d9587fa4275827c93ca9d7e0166ad1887b76cad	file_checksum_insert_ignore	goiardi_postgres	Insert ignore for file checksums	{file_checksums,goiardi_schema}	{}	{}	2015-07-15 15:25:26.582702-07	Jeremy Bingham	jeremy@goiardi.gl	2014-06-01 23:13:48-07	Jeremy Bingham	jbingham@gmail.com
revert	092885e8b5d94a9c1834bf309e02dc0f955ff053	environment_insert_update	goiardi_postgres	Insert/update environments	{environments,goiardi_schema}	{}	{}	2015-07-15 15:25:26.595535-07	Jeremy Bingham	jeremy@goiardi.gl	2014-06-01 12:55:34-07	Jeremy Bingham	jbingham@gmail.com
revert	04bea39d649e4187d9579bd946fd60f760240d10	data_bag_insert_update	goiardi_postgres	Insert/update data bags	{data_bags,goiardi_schema}	{}	{}	2015-07-15 15:25:26.609448-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-31 23:25:44-07	Jeremy Bingham	jbingham@gmail.com
revert	085e2f6281914c9fa6521d59fea81f16c106b59f	cookbook_versions_insert_update	goiardi_postgres	Cookbook versions insert/update	{cookbook_versions,goiardi_schema}	{}	{}	2015-07-15 15:25:26.623061-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-30 23:56:05-07	Jeremy Bingham	jbingham@gmail.com
revert	841a7d554d44f9d0d0b8a1a5a9d0a06ce71a2453	cookbook_insert_update	goiardi_postgres	Cookbook insert/update	{cookbooks,goiardi_schema}	{}	{}	2015-07-15 15:25:26.635868-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-30 23:55:23-07	Jeremy Bingham	jbingham@gmail.com
revert	f336c149ab32530c9c6ae4408c11558a635f39a1	user_rename	goiardi_postgres	Function to rename users	{users,goiardi_schema}	{}	{}	2015-07-15 15:25:26.649642-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-30 13:15:45-07	Jeremy Bingham	jbingham@gmail.com
revert	2d1fdc8128b0632e798df7346e76f122ed5915ec	user_insert_duplicate	goiardi_postgres	Function to emulate insert ... on duplicate update for clients	{users,goiardi_schema}	{}	{}	2015-07-15 15:25:26.664083-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-30 13:07:46-07	Jeremy Bingham	jbingham@gmail.com
revert	30774a960a0efb6adfbb1d526b8cdb1a45c7d039	client_rename	goiardi_postgres	Function to rename clients	{clients,goiardi_schema}	{}	{}	2015-07-15 15:25:26.676806-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-30 10:22:50-07	Jeremy Bingham	jbingham@gmail.com
revert	c8b38382f7e5a18f36c621327f59205aa8aa9849	client_insert_duplicate	goiardi_postgres	Function to emulate insert ... on duplicate update for clients	{clients,goiardi_schema}	{}	{}	2015-07-15 15:25:26.690599-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 23:00:04-07	Jeremy Bingham	jbingham@gmail.com
revert	db1eb360cd5e6449a468ceb781d82b45dafb5c2d	reports	goiardi_postgres	Create reports table	{}	{}	{}	2015-07-15 15:25:26.710838-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 13:02:49-07	Jeremy Bingham	jbingham@gmail.com
revert	f2621482d1c130ea8fee15d09f966685409bf67c	file_checksums	goiardi_postgres	Create file checksums table	{}	{}	{}	2015-07-15 15:25:26.740967-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 12:49:19-07	Jeremy Bingham	jbingham@gmail.com
revert	fce5b7aeed2ad742de1309d7841577cff19475a7	organizations	goiardi_postgres	Create organizations table	{}	{}	{}	2015-07-15 15:25:26.766072-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 12:46:28-07	Jeremy Bingham	jbingham@gmail.com
revert	81003655b93b41359804027fc202788aa0ddd9a9	log_infos	goiardi_postgres	Create log_infos table	{clients,users,goiardi_schema}	{}	{}	2015-07-15 15:25:26.798887-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 12:19:10-07	Jeremy Bingham	jbingham@gmail.com
revert	c4b32778f2911930f583ce15267aade320ac4dcd	sandboxes	goiardi_postgres	Create sandboxes table	{goiardi_schema}	{}	{}	2015-07-15 15:25:26.817758-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 12:14:48-07	Jeremy Bingham	jbingham@gmail.com
revert	6a4489d9436ba1541d272700b303410cc906b08f	roles	goiardi_postgres	Create roles table	{goiardi_schema}	{}	{}	2015-07-15 15:25:26.836978-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 12:09:28-07	Jeremy Bingham	jbingham@gmail.com
revert	feddf91b62caed36c790988bd29222591980433b	data_bag_items	goiardi_postgres	Create data bag items table	{data_bags,goiardi_schema}	{}	{}	2015-07-15 15:25:26.856936-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 12:02:31-07	Jeremy Bingham	jbingham@gmail.com
revert	85483913f96710c1267c6abacb6568cef9327f15	data_bags	goiardi_postgres	Create cookbook data bags table	{goiardi_schema}	{}	{}	2015-07-15 15:25:26.891764-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 11:42:04-07	Jeremy Bingham	jbingham@gmail.com
revert	f529038064a0259bdecbdab1f9f665e17ddb6136	cookbook_versions	goiardi_postgres	Create cookbook versions table	{cookbooks,goiardi_schema}	{}	{}	2015-07-15 15:25:26.91159-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 11:31:34-07	Jeremy Bingham	jbingham@gmail.com
revert	138bc49d92c0bbb024cea41532a656f2d7f9b072	cookbooks	goiardi_postgres	Create cookbook  table	{goiardi_schema}	{}	{}	2015-07-15 15:25:26.940885-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 11:27:27-07	Jeremy Bingham	jbingham@gmail.com
revert	bb82d8869ffca8ba3d03a1502c50dbb3eee7a2e0	users	goiardi_postgres	Create user table	{goiardi_schema}	{}	{}	2015-07-15 15:25:26.968817-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 11:15:02-07	Jeremy Bingham	jbingham@gmail.com
revert	faa3571aa479de60f25785e707433b304ba3d2c7	clients	goiardi_postgres	Create client table	{goiardi_schema}	{}	{}	2015-07-15 15:25:26.995711-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 11:05:33-07	Jeremy Bingham	jbingham@gmail.com
revert	911c456769628c817340ee77fc8d2b7c1d697782	nodes	goiardi_postgres	Create node table	{goiardi_schema}	{}	{}	2015-07-15 15:25:27.015759-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 10:37:46-07	Jeremy Bingham	jbingham@gmail.com
revert	367c28670efddf25455b9fd33c23a5a278b08bb4	environments	goiardi_postgres	Environments for postgres	{goiardi_schema}	{}	{}	2015-07-15 15:25:27.035142-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 00:40:11-07	Jeremy Bingham	jbingham@gmail.com
revert	c89b0e25c808b327036c88e6c9750c7526314c86	goiardi_schema	goiardi_postgres	Add schema for goiardi-postgres	{}	{}	{}	2015-07-15 15:25:27.051503-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-27 14:09:07-07	Jeremy Bingham	jbingham@gmail.com
deploy	c89b0e25c808b327036c88e6c9750c7526314c86	goiardi_schema	goiardi_postgres	Add schema for goiardi-postgres	{}	{}	{}	2015-07-15 15:25:28.442592-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-27 14:09:07-07	Jeremy Bingham	jbingham@gmail.com
deploy	367c28670efddf25455b9fd33c23a5a278b08bb4	environments	goiardi_postgres	Environments for postgres	{goiardi_schema}	{}	{}	2015-07-15 15:25:28.466072-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 00:40:11-07	Jeremy Bingham	jbingham@gmail.com
deploy	911c456769628c817340ee77fc8d2b7c1d697782	nodes	goiardi_postgres	Create node table	{goiardi_schema}	{}	{}	2015-07-15 15:25:28.487439-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 10:37:46-07	Jeremy Bingham	jbingham@gmail.com
deploy	faa3571aa479de60f25785e707433b304ba3d2c7	clients	goiardi_postgres	Create client table	{goiardi_schema}	{}	{}	2015-07-15 15:25:28.507501-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 11:05:33-07	Jeremy Bingham	jbingham@gmail.com
deploy	bb82d8869ffca8ba3d03a1502c50dbb3eee7a2e0	users	goiardi_postgres	Create user table	{goiardi_schema}	{}	{}	2015-07-15 15:25:28.528734-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 11:15:02-07	Jeremy Bingham	jbingham@gmail.com
deploy	138bc49d92c0bbb024cea41532a656f2d7f9b072	cookbooks	goiardi_postgres	Create cookbook  table	{goiardi_schema}	{}	{}	2015-07-15 15:25:28.548432-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 11:27:27-07	Jeremy Bingham	jbingham@gmail.com
deploy	f529038064a0259bdecbdab1f9f665e17ddb6136	cookbook_versions	goiardi_postgres	Create cookbook versions table	{cookbooks,goiardi_schema}	{}	{}	2015-07-15 15:25:28.575197-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 11:31:34-07	Jeremy Bingham	jbingham@gmail.com
deploy	85483913f96710c1267c6abacb6568cef9327f15	data_bags	goiardi_postgres	Create cookbook data bags table	{goiardi_schema}	{}	{}	2015-07-15 15:25:28.595955-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 11:42:04-07	Jeremy Bingham	jbingham@gmail.com
deploy	feddf91b62caed36c790988bd29222591980433b	data_bag_items	goiardi_postgres	Create data bag items table	{data_bags,goiardi_schema}	{}	{}	2015-07-15 15:25:28.61719-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 12:02:31-07	Jeremy Bingham	jbingham@gmail.com
deploy	6a4489d9436ba1541d272700b303410cc906b08f	roles	goiardi_postgres	Create roles table	{goiardi_schema}	{}	{}	2015-07-15 15:25:28.636998-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 12:09:28-07	Jeremy Bingham	jbingham@gmail.com
deploy	c4b32778f2911930f583ce15267aade320ac4dcd	sandboxes	goiardi_postgres	Create sandboxes table	{goiardi_schema}	{}	{}	2015-07-15 15:25:28.656159-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 12:14:48-07	Jeremy Bingham	jbingham@gmail.com
deploy	81003655b93b41359804027fc202788aa0ddd9a9	log_infos	goiardi_postgres	Create log_infos table	{clients,users,goiardi_schema}	{}	{}	2015-07-15 15:25:28.680009-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 12:19:10-07	Jeremy Bingham	jbingham@gmail.com
deploy	fce5b7aeed2ad742de1309d7841577cff19475a7	organizations	goiardi_postgres	Create organizations table	{}	{}	{}	2015-07-15 15:25:28.700105-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 12:46:28-07	Jeremy Bingham	jbingham@gmail.com
deploy	f2621482d1c130ea8fee15d09f966685409bf67c	file_checksums	goiardi_postgres	Create file checksums table	{}	{}	{}	2015-07-15 15:25:28.725409-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 12:49:19-07	Jeremy Bingham	jbingham@gmail.com
deploy	db1eb360cd5e6449a468ceb781d82b45dafb5c2d	reports	goiardi_postgres	Create reports table	{}	{}	{}	2015-07-15 15:25:28.75047-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 13:02:49-07	Jeremy Bingham	jbingham@gmail.com
deploy	c8b38382f7e5a18f36c621327f59205aa8aa9849	client_insert_duplicate	goiardi_postgres	Function to emulate insert ... on duplicate update for clients	{clients,goiardi_schema}	{}	{}	2015-07-15 15:25:28.766621-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 23:00:04-07	Jeremy Bingham	jbingham@gmail.com
deploy	30774a960a0efb6adfbb1d526b8cdb1a45c7d039	client_rename	goiardi_postgres	Function to rename clients	{clients,goiardi_schema}	{}	{}	2015-07-15 15:25:28.781694-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-30 10:22:50-07	Jeremy Bingham	jbingham@gmail.com
deploy	2d1fdc8128b0632e798df7346e76f122ed5915ec	user_insert_duplicate	goiardi_postgres	Function to emulate insert ... on duplicate update for clients	{users,goiardi_schema}	{}	{}	2015-07-15 15:25:28.797558-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-30 13:07:46-07	Jeremy Bingham	jbingham@gmail.com
deploy	f336c149ab32530c9c6ae4408c11558a635f39a1	user_rename	goiardi_postgres	Function to rename users	{users,goiardi_schema}	{}	{}	2015-07-15 15:25:28.814209-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-30 13:15:45-07	Jeremy Bingham	jbingham@gmail.com
deploy	841a7d554d44f9d0d0b8a1a5a9d0a06ce71a2453	cookbook_insert_update	goiardi_postgres	Cookbook insert/update	{cookbooks,goiardi_schema}	{}	{}	2015-07-15 15:25:28.829519-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-30 23:55:23-07	Jeremy Bingham	jbingham@gmail.com
deploy	085e2f6281914c9fa6521d59fea81f16c106b59f	cookbook_versions_insert_update	goiardi_postgres	Cookbook versions insert/update	{cookbook_versions,goiardi_schema}	{}	{}	2015-07-15 15:25:28.845246-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-30 23:56:05-07	Jeremy Bingham	jbingham@gmail.com
deploy	04bea39d649e4187d9579bd946fd60f760240d10	data_bag_insert_update	goiardi_postgres	Insert/update data bags	{data_bags,goiardi_schema}	{}	{}	2015-07-15 15:25:28.860652-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-31 23:25:44-07	Jeremy Bingham	jbingham@gmail.com
deploy	092885e8b5d94a9c1834bf309e02dc0f955ff053	environment_insert_update	goiardi_postgres	Insert/update environments	{environments,goiardi_schema}	{}	{}	2015-07-15 15:25:28.876534-07	Jeremy Bingham	jeremy@goiardi.gl	2014-06-01 12:55:34-07	Jeremy Bingham	jbingham@gmail.com
deploy	6d9587fa4275827c93ca9d7e0166ad1887b76cad	file_checksum_insert_ignore	goiardi_postgres	Insert ignore for file checksums	{file_checksums,goiardi_schema}	{}	{}	2015-07-15 15:25:28.89239-07	Jeremy Bingham	jeremy@goiardi.gl	2014-06-01 23:13:48-07	Jeremy Bingham	jbingham@gmail.com
deploy	82a95e5e6cbd8ba51fea33506e1edb2a12e37a92	node_insert_update	goiardi_postgres	Insert/update for nodes	{nodes,goiardi_schema}	{}	{}	2015-07-15 15:25:28.908667-07	Jeremy Bingham	jeremy@goiardi.gl	2014-06-01 23:25:20-07	Jeremy Bingham	jbingham@gmail.com
deploy	d052a8267a6512581e5cab1f89a2456f279727b9	report_insert_update	goiardi_postgres	Insert/update for reports	{reports,goiardi_schema}	{}	{}	2015-07-15 15:25:28.926214-07	Jeremy Bingham	jeremy@goiardi.gl	2014-06-02 10:10:25-07	Jeremy Bingham	jbingham@gmail.com
deploy	acf76029633d50febbec7c4763b7173078eddaf7	role_insert_update	goiardi_postgres	Insert/update for roles	{roles,goiardi_schema}	{}	{}	2015-07-15 15:25:28.941026-07	Jeremy Bingham	jeremy@goiardi.gl	2014-06-02 10:27:32-07	Jeremy Bingham	jbingham@gmail.com
deploy	b8ef36df686397ecb0fe67eb097e84aa0d78ac6b	sandbox_insert_update	goiardi_postgres	Insert/update for sandboxes	{sandboxes,goiardi_schema}	{}	{}	2015-07-15 15:25:28.956777-07	Jeremy Bingham	jeremy@goiardi.gl	2014-06-02 10:34:39-07	Jeremy Bingham	jbingham@gmail.com
deploy	93dbbda50a25da0a586e89ccee8fcfa2ddcb7c64	data_bag_item_insert	goiardi_postgres	Insert for data bag items	{data_bag_items,data_bags,goiardi_schema}	{}	{@v0.6.0}	2015-07-15 15:25:28.974549-07	Jeremy Bingham	jeremy@goiardi.gl	2014-06-02 14:03:22-07	Jeremy Bingham	jbingham@gmail.com
deploy	c80c561c22f6e139165cdb338c7ce6fff8ff268d	bytea_to_json	goiardi_postgres	Change most postgres bytea fields to json, because in this peculiar case json is way faster than gob	{}	{}	{}	2015-07-15 15:25:29.031717-07	Jeremy Bingham	jeremy@goiardi.gl	2014-07-20 02:41:22-07	Jeremy Bingham	jbingham@gmail.com
deploy	9966894e0fc0da573243f6a3c0fc1432a2b63043	joined_cookbkook_version	goiardi_postgres	a convenient view for joined versions for cookbook versions, adapted from erchef's joined_cookbook_version	{}	{}	{@v0.7.0}	2015-07-15 15:25:29.059067-07	Jeremy Bingham	jeremy@goiardi.gl	2014-07-20 03:21:28-07	Jeremy Bingham	jbingham@gmail.com
deploy	163ba4a496b9b4210d335e0e4ea5368a9ea8626c	node_statuses	goiardi_postgres	Create node_status table for node statuses	{nodes}	{}	{}	2015-07-15 15:25:29.080427-07	Jeremy Bingham	jeremy@goiardi.gl	2014-07-10 23:01:54-07	Jeremy Bingham	jeremy@terqa.local
deploy	8bb822f391b499585cfb2fc7248be469b0200682	node_status_insert	goiardi_postgres	insert function for node_statuses	{node_statuses}	{}	{}	2015-07-15 15:25:29.095809-07	Jeremy Bingham	jeremy@goiardi.gl	2014-07-11 00:01:31-07	Jeremy Bingham	jeremy@terqa.local
deploy	7c429aac08527adc774767584201f668408b04a6	add_down_column_nodes	goiardi_postgres	Add is_down column to the nodes table	{nodes}	{}	{}	2015-07-15 15:25:29.118527-07	Jeremy Bingham	jeremy@goiardi.gl	2014-07-15 20:18:05-07	Jeremy Bingham	jbingham@gmail.com
deploy	82bcace325dbdc905eb6e677f800d14a0506a216	shovey	goiardi_postgres	add shovey tables	{}	{}	{}	2015-07-15 15:25:29.150213-07	Jeremy Bingham	jeremy@goiardi.gl	2014-07-15 22:07:12-07	Jeremy Bingham	jeremy@terqa.local
deploy	62046d2fb96bbaedce2406252d312766452551c0	node_latest_statuses	goiardi_postgres	Add a view to easily get nodes by their latest status	{node_statuses}	{}	{}	2015-07-15 15:25:29.166827-07	Jeremy Bingham	jeremy@goiardi.gl	2014-07-26 13:32:02-07	Jeremy Bingham	jbingham@gmail.com
deploy	68f90e1fd2aac6a117d7697626741a02b8d0ebbe	shovey_insert_update	goiardi_postgres	insert/update functions for shovey	{shovey}	{}	{@v0.8.0}	2015-07-15 15:25:29.1848-07	Jeremy Bingham	jeremy@goiardi.gl	2014-08-27 00:46:20-07	Jeremy Bingham	jbingham@gmail.com
deploy	6f7aa2430e01cf33715828f1957d072cd5006d1c	ltree	goiardi_postgres	Add tables for ltree search for postgres	{}	{}	{}	2015-07-15 15:25:29.261075-07	Jeremy Bingham	jeremy@goiardi.gl	2015-04-10 23:21:26-07	Jeremy Bingham	jeremy@goiardi.gl
deploy	e7eb33b00d2fb6302e0c3979e9cac6fb80da377e	ltree_del_col	goiardi_postgres	procedure for deleting search collections	{}	{}	{}	2015-07-15 15:25:29.279833-07	Jeremy Bingham	jeremy@goiardi.gl	2015-04-12 12:33:15-07	Jeremy Bingham	jeremy@goiardi.gl
deploy	f49decbb15053ec5691093568450f642578ca460	ltree_del_item	goiardi_postgres	procedure for deleting search items	{}	{}	{}	2015-07-15 15:25:29.2943-07	Jeremy Bingham	jeremy@goiardi.gl	2015-04-12 13:03:50-07	Jeremy Bingham	jeremy@goiardi.gl
revert	f49decbb15053ec5691093568450f642578ca460	ltree_del_item	goiardi_postgres	procedure for deleting search items	{}	{}	{}	2015-07-22 14:56:00.493063-07	Jeremy Bingham	jeremy@goiardi.gl	2015-04-12 13:03:50-07	Jeremy Bingham	jeremy@goiardi.gl
revert	e7eb33b00d2fb6302e0c3979e9cac6fb80da377e	ltree_del_col	goiardi_postgres	procedure for deleting search collections	{}	{}	{}	2015-07-22 14:56:00.515123-07	Jeremy Bingham	jeremy@goiardi.gl	2015-04-12 12:33:15-07	Jeremy Bingham	jeremy@goiardi.gl
revert	6f7aa2430e01cf33715828f1957d072cd5006d1c	ltree	goiardi_postgres	Add tables for ltree search for postgres	{}	{}	{}	2015-07-22 14:56:00.643423-07	Jeremy Bingham	jeremy@goiardi.gl	2015-04-10 23:21:26-07	Jeremy Bingham	jeremy@goiardi.gl
revert	68f90e1fd2aac6a117d7697626741a02b8d0ebbe	shovey_insert_update	goiardi_postgres	insert/update functions for shovey	{shovey}	{}	{@v0.8.0}	2015-07-22 14:56:00.659371-07	Jeremy Bingham	jeremy@goiardi.gl	2014-08-27 00:46:20-07	Jeremy Bingham	jbingham@gmail.com
revert	62046d2fb96bbaedce2406252d312766452551c0	node_latest_statuses	goiardi_postgres	Add a view to easily get nodes by their latest status	{node_statuses}	{}	{}	2015-07-22 14:56:00.676009-07	Jeremy Bingham	jeremy@goiardi.gl	2014-07-26 13:32:02-07	Jeremy Bingham	jbingham@gmail.com
revert	82bcace325dbdc905eb6e677f800d14a0506a216	shovey	goiardi_postgres	add shovey tables	{}	{}	{}	2015-07-22 14:56:00.734902-07	Jeremy Bingham	jeremy@goiardi.gl	2014-07-15 22:07:12-07	Jeremy Bingham	jeremy@terqa.local
revert	7c429aac08527adc774767584201f668408b04a6	add_down_column_nodes	goiardi_postgres	Add is_down column to the nodes table	{nodes}	{}	{}	2015-07-22 14:56:00.75966-07	Jeremy Bingham	jeremy@goiardi.gl	2014-07-15 20:18:05-07	Jeremy Bingham	jbingham@gmail.com
revert	8bb822f391b499585cfb2fc7248be469b0200682	node_status_insert	goiardi_postgres	insert function for node_statuses	{node_statuses}	{}	{}	2015-07-22 14:56:00.778662-07	Jeremy Bingham	jeremy@goiardi.gl	2014-07-11 00:01:31-07	Jeremy Bingham	jeremy@terqa.local
revert	163ba4a496b9b4210d335e0e4ea5368a9ea8626c	node_statuses	goiardi_postgres	Create node_status table for node statuses	{nodes}	{}	{}	2015-07-22 14:56:00.808952-07	Jeremy Bingham	jeremy@goiardi.gl	2014-07-10 23:01:54-07	Jeremy Bingham	jeremy@terqa.local
revert	9966894e0fc0da573243f6a3c0fc1432a2b63043	joined_cookbkook_version	goiardi_postgres	a convenient view for joined versions for cookbook versions, adapted from erchef's joined_cookbook_version	{}	{}	{@v0.7.0}	2015-07-22 14:56:00.823937-07	Jeremy Bingham	jeremy@goiardi.gl	2014-07-20 03:21:28-07	Jeremy Bingham	jbingham@gmail.com
revert	c80c561c22f6e139165cdb338c7ce6fff8ff268d	bytea_to_json	goiardi_postgres	Change most postgres bytea fields to json, because in this peculiar case json is way faster than gob	{}	{}	{}	2015-07-22 14:56:00.994362-07	Jeremy Bingham	jeremy@goiardi.gl	2014-07-20 02:41:22-07	Jeremy Bingham	jbingham@gmail.com
revert	93dbbda50a25da0a586e89ccee8fcfa2ddcb7c64	data_bag_item_insert	goiardi_postgres	Insert for data bag items	{data_bag_items,data_bags,goiardi_schema}	{}	{@v0.6.0}	2015-07-22 14:56:01.011777-07	Jeremy Bingham	jeremy@goiardi.gl	2014-06-02 14:03:22-07	Jeremy Bingham	jbingham@gmail.com
revert	b8ef36df686397ecb0fe67eb097e84aa0d78ac6b	sandbox_insert_update	goiardi_postgres	Insert/update for sandboxes	{sandboxes,goiardi_schema}	{}	{}	2015-07-22 14:56:01.031175-07	Jeremy Bingham	jeremy@goiardi.gl	2014-06-02 10:34:39-07	Jeremy Bingham	jbingham@gmail.com
revert	acf76029633d50febbec7c4763b7173078eddaf7	role_insert_update	goiardi_postgres	Insert/update for roles	{roles,goiardi_schema}	{}	{}	2015-07-22 14:56:01.045572-07	Jeremy Bingham	jeremy@goiardi.gl	2014-06-02 10:27:32-07	Jeremy Bingham	jbingham@gmail.com
revert	d052a8267a6512581e5cab1f89a2456f279727b9	report_insert_update	goiardi_postgres	Insert/update for reports	{reports,goiardi_schema}	{}	{}	2015-07-22 14:56:01.059855-07	Jeremy Bingham	jeremy@goiardi.gl	2014-06-02 10:10:25-07	Jeremy Bingham	jbingham@gmail.com
revert	82a95e5e6cbd8ba51fea33506e1edb2a12e37a92	node_insert_update	goiardi_postgres	Insert/update for nodes	{nodes,goiardi_schema}	{}	{}	2015-07-22 14:56:01.074448-07	Jeremy Bingham	jeremy@goiardi.gl	2014-06-01 23:25:20-07	Jeremy Bingham	jbingham@gmail.com
revert	6d9587fa4275827c93ca9d7e0166ad1887b76cad	file_checksum_insert_ignore	goiardi_postgres	Insert ignore for file checksums	{file_checksums,goiardi_schema}	{}	{}	2015-07-22 14:56:01.088911-07	Jeremy Bingham	jeremy@goiardi.gl	2014-06-01 23:13:48-07	Jeremy Bingham	jbingham@gmail.com
revert	092885e8b5d94a9c1834bf309e02dc0f955ff053	environment_insert_update	goiardi_postgres	Insert/update environments	{environments,goiardi_schema}	{}	{}	2015-07-22 14:56:01.103575-07	Jeremy Bingham	jeremy@goiardi.gl	2014-06-01 12:55:34-07	Jeremy Bingham	jbingham@gmail.com
revert	04bea39d649e4187d9579bd946fd60f760240d10	data_bag_insert_update	goiardi_postgres	Insert/update data bags	{data_bags,goiardi_schema}	{}	{}	2015-07-22 14:56:01.118026-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-31 23:25:44-07	Jeremy Bingham	jbingham@gmail.com
revert	085e2f6281914c9fa6521d59fea81f16c106b59f	cookbook_versions_insert_update	goiardi_postgres	Cookbook versions insert/update	{cookbook_versions,goiardi_schema}	{}	{}	2015-07-22 14:56:01.131227-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-30 23:56:05-07	Jeremy Bingham	jbingham@gmail.com
revert	841a7d554d44f9d0d0b8a1a5a9d0a06ce71a2453	cookbook_insert_update	goiardi_postgres	Cookbook insert/update	{cookbooks,goiardi_schema}	{}	{}	2015-07-22 14:56:01.145996-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-30 23:55:23-07	Jeremy Bingham	jbingham@gmail.com
revert	f336c149ab32530c9c6ae4408c11558a635f39a1	user_rename	goiardi_postgres	Function to rename users	{users,goiardi_schema}	{}	{}	2015-07-22 14:56:01.161999-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-30 13:15:45-07	Jeremy Bingham	jbingham@gmail.com
revert	2d1fdc8128b0632e798df7346e76f122ed5915ec	user_insert_duplicate	goiardi_postgres	Function to emulate insert ... on duplicate update for clients	{users,goiardi_schema}	{}	{}	2015-07-22 14:56:01.175535-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-30 13:07:46-07	Jeremy Bingham	jbingham@gmail.com
revert	30774a960a0efb6adfbb1d526b8cdb1a45c7d039	client_rename	goiardi_postgres	Function to rename clients	{clients,goiardi_schema}	{}	{}	2015-07-22 14:56:01.190414-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-30 10:22:50-07	Jeremy Bingham	jbingham@gmail.com
revert	c8b38382f7e5a18f36c621327f59205aa8aa9849	client_insert_duplicate	goiardi_postgres	Function to emulate insert ... on duplicate update for clients	{clients,goiardi_schema}	{}	{}	2015-07-22 14:56:01.204988-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 23:00:04-07	Jeremy Bingham	jbingham@gmail.com
revert	db1eb360cd5e6449a468ceb781d82b45dafb5c2d	reports	goiardi_postgres	Create reports table	{}	{}	{}	2015-07-22 14:56:01.224909-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 13:02:49-07	Jeremy Bingham	jbingham@gmail.com
revert	f2621482d1c130ea8fee15d09f966685409bf67c	file_checksums	goiardi_postgres	Create file checksums table	{}	{}	{}	2015-07-22 14:56:01.250648-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 12:49:19-07	Jeremy Bingham	jbingham@gmail.com
revert	fce5b7aeed2ad742de1309d7841577cff19475a7	organizations	goiardi_postgres	Create organizations table	{}	{}	{}	2015-07-22 14:56:01.276786-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 12:46:28-07	Jeremy Bingham	jbingham@gmail.com
revert	81003655b93b41359804027fc202788aa0ddd9a9	log_infos	goiardi_postgres	Create log_infos table	{clients,users,goiardi_schema}	{}	{}	2015-07-22 14:56:01.308908-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 12:19:10-07	Jeremy Bingham	jbingham@gmail.com
revert	c4b32778f2911930f583ce15267aade320ac4dcd	sandboxes	goiardi_postgres	Create sandboxes table	{goiardi_schema}	{}	{}	2015-07-22 14:56:01.328879-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 12:14:48-07	Jeremy Bingham	jbingham@gmail.com
revert	6a4489d9436ba1541d272700b303410cc906b08f	roles	goiardi_postgres	Create roles table	{goiardi_schema}	{}	{}	2015-07-22 14:56:01.348632-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 12:09:28-07	Jeremy Bingham	jbingham@gmail.com
revert	feddf91b62caed36c790988bd29222591980433b	data_bag_items	goiardi_postgres	Create data bag items table	{data_bags,goiardi_schema}	{}	{}	2015-07-22 14:56:01.368563-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 12:02:31-07	Jeremy Bingham	jbingham@gmail.com
revert	85483913f96710c1267c6abacb6568cef9327f15	data_bags	goiardi_postgres	Create cookbook data bags table	{goiardi_schema}	{}	{}	2015-07-22 14:56:01.398086-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 11:42:04-07	Jeremy Bingham	jbingham@gmail.com
revert	f529038064a0259bdecbdab1f9f665e17ddb6136	cookbook_versions	goiardi_postgres	Create cookbook versions table	{cookbooks,goiardi_schema}	{}	{}	2015-07-22 14:56:01.418697-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 11:31:34-07	Jeremy Bingham	jbingham@gmail.com
revert	138bc49d92c0bbb024cea41532a656f2d7f9b072	cookbooks	goiardi_postgres	Create cookbook  table	{goiardi_schema}	{}	{}	2015-07-22 14:56:01.446968-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 11:27:27-07	Jeremy Bingham	jbingham@gmail.com
revert	bb82d8869ffca8ba3d03a1502c50dbb3eee7a2e0	users	goiardi_postgres	Create user table	{goiardi_schema}	{}	{}	2015-07-22 14:56:01.482954-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 11:15:02-07	Jeremy Bingham	jbingham@gmail.com
revert	faa3571aa479de60f25785e707433b304ba3d2c7	clients	goiardi_postgres	Create client table	{goiardi_schema}	{}	{}	2015-07-22 14:56:01.521624-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 11:05:33-07	Jeremy Bingham	jbingham@gmail.com
revert	911c456769628c817340ee77fc8d2b7c1d697782	nodes	goiardi_postgres	Create node table	{goiardi_schema}	{}	{}	2015-07-22 14:56:01.550745-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 10:37:46-07	Jeremy Bingham	jbingham@gmail.com
revert	367c28670efddf25455b9fd33c23a5a278b08bb4	environments	goiardi_postgres	Environments for postgres	{goiardi_schema}	{}	{}	2015-07-22 14:56:01.571755-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 00:40:11-07	Jeremy Bingham	jbingham@gmail.com
revert	c89b0e25c808b327036c88e6c9750c7526314c86	goiardi_schema	goiardi_postgres	Add schema for goiardi-postgres	{}	{}	{}	2015-07-22 14:56:01.585525-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-27 14:09:07-07	Jeremy Bingham	jbingham@gmail.com
deploy	c89b0e25c808b327036c88e6c9750c7526314c86	goiardi_schema	goiardi_postgres	Add schema for goiardi-postgres	{}	{}	{}	2015-07-22 14:56:04.277643-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-27 14:09:07-07	Jeremy Bingham	jbingham@gmail.com
deploy	367c28670efddf25455b9fd33c23a5a278b08bb4	environments	goiardi_postgres	Environments for postgres	{goiardi_schema}	{}	{}	2015-07-22 14:56:04.305546-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 00:40:11-07	Jeremy Bingham	jbingham@gmail.com
deploy	911c456769628c817340ee77fc8d2b7c1d697782	nodes	goiardi_postgres	Create node table	{goiardi_schema}	{}	{}	2015-07-22 14:56:04.327547-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 10:37:46-07	Jeremy Bingham	jbingham@gmail.com
deploy	faa3571aa479de60f25785e707433b304ba3d2c7	clients	goiardi_postgres	Create client table	{goiardi_schema}	{}	{}	2015-07-22 14:56:04.348538-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 11:05:33-07	Jeremy Bingham	jbingham@gmail.com
deploy	bb82d8869ffca8ba3d03a1502c50dbb3eee7a2e0	users	goiardi_postgres	Create user table	{goiardi_schema}	{}	{}	2015-07-22 14:56:04.371499-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 11:15:02-07	Jeremy Bingham	jbingham@gmail.com
deploy	138bc49d92c0bbb024cea41532a656f2d7f9b072	cookbooks	goiardi_postgres	Create cookbook  table	{goiardi_schema}	{}	{}	2015-07-22 14:56:04.391299-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 11:27:27-07	Jeremy Bingham	jbingham@gmail.com
deploy	f529038064a0259bdecbdab1f9f665e17ddb6136	cookbook_versions	goiardi_postgres	Create cookbook versions table	{cookbooks,goiardi_schema}	{}	{}	2015-07-22 14:56:04.414343-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 11:31:34-07	Jeremy Bingham	jbingham@gmail.com
deploy	85483913f96710c1267c6abacb6568cef9327f15	data_bags	goiardi_postgres	Create cookbook data bags table	{goiardi_schema}	{}	{}	2015-07-22 14:56:04.437696-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 11:42:04-07	Jeremy Bingham	jbingham@gmail.com
deploy	feddf91b62caed36c790988bd29222591980433b	data_bag_items	goiardi_postgres	Create data bag items table	{data_bags,goiardi_schema}	{}	{}	2015-07-22 14:56:04.457954-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 12:02:31-07	Jeremy Bingham	jbingham@gmail.com
deploy	6a4489d9436ba1541d272700b303410cc906b08f	roles	goiardi_postgres	Create roles table	{goiardi_schema}	{}	{}	2015-07-22 14:56:04.485408-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 12:09:28-07	Jeremy Bingham	jbingham@gmail.com
deploy	c4b32778f2911930f583ce15267aade320ac4dcd	sandboxes	goiardi_postgres	Create sandboxes table	{goiardi_schema}	{}	{}	2015-07-22 14:56:04.506942-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 12:14:48-07	Jeremy Bingham	jbingham@gmail.com
deploy	81003655b93b41359804027fc202788aa0ddd9a9	log_infos	goiardi_postgres	Create log_infos table	{clients,users,goiardi_schema}	{}	{}	2015-07-22 14:56:04.547733-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 12:19:10-07	Jeremy Bingham	jbingham@gmail.com
deploy	fce5b7aeed2ad742de1309d7841577cff19475a7	organizations	goiardi_postgres	Create organizations table	{}	{}	{}	2015-07-22 14:56:04.568937-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 12:46:28-07	Jeremy Bingham	jbingham@gmail.com
deploy	f2621482d1c130ea8fee15d09f966685409bf67c	file_checksums	goiardi_postgres	Create file checksums table	{}	{}	{}	2015-07-22 14:56:04.588331-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 12:49:19-07	Jeremy Bingham	jbingham@gmail.com
deploy	db1eb360cd5e6449a468ceb781d82b45dafb5c2d	reports	goiardi_postgres	Create reports table	{}	{}	{}	2015-07-22 14:56:04.61587-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 13:02:49-07	Jeremy Bingham	jbingham@gmail.com
deploy	c8b38382f7e5a18f36c621327f59205aa8aa9849	client_insert_duplicate	goiardi_postgres	Function to emulate insert ... on duplicate update for clients	{clients,goiardi_schema}	{}	{}	2015-07-22 14:56:04.631926-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 23:00:04-07	Jeremy Bingham	jbingham@gmail.com
deploy	30774a960a0efb6adfbb1d526b8cdb1a45c7d039	client_rename	goiardi_postgres	Function to rename clients	{clients,goiardi_schema}	{}	{}	2015-07-22 14:56:04.647847-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-30 10:22:50-07	Jeremy Bingham	jbingham@gmail.com
deploy	2d1fdc8128b0632e798df7346e76f122ed5915ec	user_insert_duplicate	goiardi_postgres	Function to emulate insert ... on duplicate update for clients	{users,goiardi_schema}	{}	{}	2015-07-22 14:56:04.665069-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-30 13:07:46-07	Jeremy Bingham	jbingham@gmail.com
deploy	f336c149ab32530c9c6ae4408c11558a635f39a1	user_rename	goiardi_postgres	Function to rename users	{users,goiardi_schema}	{}	{}	2015-07-22 14:56:04.680829-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-30 13:15:45-07	Jeremy Bingham	jbingham@gmail.com
deploy	841a7d554d44f9d0d0b8a1a5a9d0a06ce71a2453	cookbook_insert_update	goiardi_postgres	Cookbook insert/update	{cookbooks,goiardi_schema}	{}	{}	2015-07-22 14:56:04.701054-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-30 23:55:23-07	Jeremy Bingham	jbingham@gmail.com
deploy	085e2f6281914c9fa6521d59fea81f16c106b59f	cookbook_versions_insert_update	goiardi_postgres	Cookbook versions insert/update	{cookbook_versions,goiardi_schema}	{}	{}	2015-07-22 14:56:04.722285-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-30 23:56:05-07	Jeremy Bingham	jbingham@gmail.com
deploy	04bea39d649e4187d9579bd946fd60f760240d10	data_bag_insert_update	goiardi_postgres	Insert/update data bags	{data_bags,goiardi_schema}	{}	{}	2015-07-22 14:56:04.744219-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-31 23:25:44-07	Jeremy Bingham	jbingham@gmail.com
deploy	092885e8b5d94a9c1834bf309e02dc0f955ff053	environment_insert_update	goiardi_postgres	Insert/update environments	{environments,goiardi_schema}	{}	{}	2015-07-22 14:56:04.761206-07	Jeremy Bingham	jeremy@goiardi.gl	2014-06-01 12:55:34-07	Jeremy Bingham	jbingham@gmail.com
deploy	6d9587fa4275827c93ca9d7e0166ad1887b76cad	file_checksum_insert_ignore	goiardi_postgres	Insert ignore for file checksums	{file_checksums,goiardi_schema}	{}	{}	2015-07-22 14:56:04.782084-07	Jeremy Bingham	jeremy@goiardi.gl	2014-06-01 23:13:48-07	Jeremy Bingham	jbingham@gmail.com
deploy	82a95e5e6cbd8ba51fea33506e1edb2a12e37a92	node_insert_update	goiardi_postgres	Insert/update for nodes	{nodes,goiardi_schema}	{}	{}	2015-07-22 14:56:04.797699-07	Jeremy Bingham	jeremy@goiardi.gl	2014-06-01 23:25:20-07	Jeremy Bingham	jbingham@gmail.com
deploy	d052a8267a6512581e5cab1f89a2456f279727b9	report_insert_update	goiardi_postgres	Insert/update for reports	{reports,goiardi_schema}	{}	{}	2015-07-22 14:56:04.813367-07	Jeremy Bingham	jeremy@goiardi.gl	2014-06-02 10:10:25-07	Jeremy Bingham	jbingham@gmail.com
deploy	acf76029633d50febbec7c4763b7173078eddaf7	role_insert_update	goiardi_postgres	Insert/update for roles	{roles,goiardi_schema}	{}	{}	2015-07-22 14:56:04.829002-07	Jeremy Bingham	jeremy@goiardi.gl	2014-06-02 10:27:32-07	Jeremy Bingham	jbingham@gmail.com
deploy	b8ef36df686397ecb0fe67eb097e84aa0d78ac6b	sandbox_insert_update	goiardi_postgres	Insert/update for sandboxes	{sandboxes,goiardi_schema}	{}	{}	2015-07-22 14:56:04.845122-07	Jeremy Bingham	jeremy@goiardi.gl	2014-06-02 10:34:39-07	Jeremy Bingham	jbingham@gmail.com
deploy	93dbbda50a25da0a586e89ccee8fcfa2ddcb7c64	data_bag_item_insert	goiardi_postgres	Insert for data bag items	{data_bag_items,data_bags,goiardi_schema}	{}	{@v0.6.0}	2015-07-22 14:56:04.863012-07	Jeremy Bingham	jeremy@goiardi.gl	2014-06-02 14:03:22-07	Jeremy Bingham	jbingham@gmail.com
deploy	c80c561c22f6e139165cdb338c7ce6fff8ff268d	bytea_to_json	goiardi_postgres	Change most postgres bytea fields to json, because in this peculiar case json is way faster than gob	{}	{}	{}	2015-07-22 14:56:04.914232-07	Jeremy Bingham	jeremy@goiardi.gl	2014-07-20 02:41:22-07	Jeremy Bingham	jbingham@gmail.com
deploy	9966894e0fc0da573243f6a3c0fc1432a2b63043	joined_cookbkook_version	goiardi_postgres	a convenient view for joined versions for cookbook versions, adapted from erchef's joined_cookbook_version	{}	{}	{@v0.7.0}	2015-07-22 14:56:04.939577-07	Jeremy Bingham	jeremy@goiardi.gl	2014-07-20 03:21:28-07	Jeremy Bingham	jbingham@gmail.com
deploy	163ba4a496b9b4210d335e0e4ea5368a9ea8626c	node_statuses	goiardi_postgres	Create node_status table for node statuses	{nodes}	{}	{}	2015-07-22 14:56:04.961248-07	Jeremy Bingham	jeremy@goiardi.gl	2014-07-10 23:01:54-07	Jeremy Bingham	jeremy@terqa.local
deploy	8bb822f391b499585cfb2fc7248be469b0200682	node_status_insert	goiardi_postgres	insert function for node_statuses	{node_statuses}	{}	{}	2015-07-22 14:56:04.977223-07	Jeremy Bingham	jeremy@goiardi.gl	2014-07-11 00:01:31-07	Jeremy Bingham	jeremy@terqa.local
deploy	7c429aac08527adc774767584201f668408b04a6	add_down_column_nodes	goiardi_postgres	Add is_down column to the nodes table	{nodes}	{}	{}	2015-07-22 14:56:05.001536-07	Jeremy Bingham	jeremy@goiardi.gl	2014-07-15 20:18:05-07	Jeremy Bingham	jbingham@gmail.com
deploy	82bcace325dbdc905eb6e677f800d14a0506a216	shovey	goiardi_postgres	add shovey tables	{}	{}	{}	2015-07-22 14:56:05.038583-07	Jeremy Bingham	jeremy@goiardi.gl	2014-07-15 22:07:12-07	Jeremy Bingham	jeremy@terqa.local
deploy	62046d2fb96bbaedce2406252d312766452551c0	node_latest_statuses	goiardi_postgres	Add a view to easily get nodes by their latest status	{node_statuses}	{}	{}	2015-07-22 14:56:05.060414-07	Jeremy Bingham	jeremy@goiardi.gl	2014-07-26 13:32:02-07	Jeremy Bingham	jbingham@gmail.com
deploy	68f90e1fd2aac6a117d7697626741a02b8d0ebbe	shovey_insert_update	goiardi_postgres	insert/update functions for shovey	{shovey}	{}	{@v0.8.0}	2015-07-22 14:56:05.082495-07	Jeremy Bingham	jeremy@goiardi.gl	2014-08-27 00:46:20-07	Jeremy Bingham	jbingham@gmail.com
deploy	6f7aa2430e01cf33715828f1957d072cd5006d1c	ltree	goiardi_postgres	Add tables for ltree search for postgres	{}	{}	{}	2015-07-22 14:56:05.170347-07	Jeremy Bingham	jeremy@goiardi.gl	2015-04-10 23:21:26-07	Jeremy Bingham	jeremy@goiardi.gl
deploy	e7eb33b00d2fb6302e0c3979e9cac6fb80da377e	ltree_del_col	goiardi_postgres	procedure for deleting search collections	{}	{}	{}	2015-07-22 14:56:05.186165-07	Jeremy Bingham	jeremy@goiardi.gl	2015-04-12 12:33:15-07	Jeremy Bingham	jeremy@goiardi.gl
deploy	f49decbb15053ec5691093568450f642578ca460	ltree_del_item	goiardi_postgres	procedure for deleting search items	{}	{}	{}	2015-07-22 14:56:05.202371-07	Jeremy Bingham	jeremy@goiardi.gl	2015-04-12 13:03:50-07	Jeremy Bingham	jeremy@goiardi.gl
revert	f49decbb15053ec5691093568450f642578ca460	ltree_del_item	goiardi_postgres	procedure for deleting search items	{}	{}	{}	2015-07-22 15:09:12.54063-07	Jeremy Bingham	jeremy@goiardi.gl	2015-04-12 13:03:50-07	Jeremy Bingham	jeremy@goiardi.gl
revert	e7eb33b00d2fb6302e0c3979e9cac6fb80da377e	ltree_del_col	goiardi_postgres	procedure for deleting search collections	{}	{}	{}	2015-07-22 15:09:12.556597-07	Jeremy Bingham	jeremy@goiardi.gl	2015-04-12 12:33:15-07	Jeremy Bingham	jeremy@goiardi.gl
revert	6f7aa2430e01cf33715828f1957d072cd5006d1c	ltree	goiardi_postgres	Add tables for ltree search for postgres	{}	{}	{}	2015-07-22 15:09:12.596647-07	Jeremy Bingham	jeremy@goiardi.gl	2015-04-10 23:21:26-07	Jeremy Bingham	jeremy@goiardi.gl
revert	f49decbb15053ec5691093568450f642578ca460	ltree_del_item	goiardi_postgres	procedure for deleting search items	{}	{}	{}	2015-07-22 15:16:13.956346-07	Jeremy Bingham	jeremy@goiardi.gl	2015-04-12 13:03:50-07	Jeremy Bingham	jeremy@goiardi.gl
revert	68f90e1fd2aac6a117d7697626741a02b8d0ebbe	shovey_insert_update	goiardi_postgres	insert/update functions for shovey	{shovey}	{}	{@v0.8.0}	2015-07-22 15:09:12.615264-07	Jeremy Bingham	jeremy@goiardi.gl	2014-08-27 00:46:20-07	Jeremy Bingham	jbingham@gmail.com
revert	62046d2fb96bbaedce2406252d312766452551c0	node_latest_statuses	goiardi_postgres	Add a view to easily get nodes by their latest status	{node_statuses}	{}	{}	2015-07-22 15:09:12.632662-07	Jeremy Bingham	jeremy@goiardi.gl	2014-07-26 13:32:02-07	Jeremy Bingham	jbingham@gmail.com
revert	82bcace325dbdc905eb6e677f800d14a0506a216	shovey	goiardi_postgres	add shovey tables	{}	{}	{}	2015-07-22 15:09:12.658557-07	Jeremy Bingham	jeremy@goiardi.gl	2014-07-15 22:07:12-07	Jeremy Bingham	jeremy@terqa.local
revert	7c429aac08527adc774767584201f668408b04a6	add_down_column_nodes	goiardi_postgres	Add is_down column to the nodes table	{nodes}	{}	{}	2015-07-22 15:09:12.675507-07	Jeremy Bingham	jeremy@goiardi.gl	2014-07-15 20:18:05-07	Jeremy Bingham	jbingham@gmail.com
revert	8bb822f391b499585cfb2fc7248be469b0200682	node_status_insert	goiardi_postgres	insert function for node_statuses	{node_statuses}	{}	{}	2015-07-22 15:09:12.691527-07	Jeremy Bingham	jeremy@goiardi.gl	2014-07-11 00:01:31-07	Jeremy Bingham	jeremy@terqa.local
revert	163ba4a496b9b4210d335e0e4ea5368a9ea8626c	node_statuses	goiardi_postgres	Create node_status table for node statuses	{nodes}	{}	{}	2015-07-22 15:09:12.710484-07	Jeremy Bingham	jeremy@goiardi.gl	2014-07-10 23:01:54-07	Jeremy Bingham	jeremy@terqa.local
revert	9966894e0fc0da573243f6a3c0fc1432a2b63043	joined_cookbkook_version	goiardi_postgres	a convenient view for joined versions for cookbook versions, adapted from erchef's joined_cookbook_version	{}	{}	{@v0.7.0}	2015-07-22 15:09:12.7271-07	Jeremy Bingham	jeremy@goiardi.gl	2014-07-20 03:21:28-07	Jeremy Bingham	jbingham@gmail.com
revert	c80c561c22f6e139165cdb338c7ce6fff8ff268d	bytea_to_json	goiardi_postgres	Change most postgres bytea fields to json, because in this peculiar case json is way faster than gob	{}	{}	{}	2015-07-22 15:09:12.797269-07	Jeremy Bingham	jeremy@goiardi.gl	2014-07-20 02:41:22-07	Jeremy Bingham	jbingham@gmail.com
revert	93dbbda50a25da0a586e89ccee8fcfa2ddcb7c64	data_bag_item_insert	goiardi_postgres	Insert for data bag items	{data_bag_items,data_bags,goiardi_schema}	{}	{@v0.6.0}	2015-07-22 15:09:12.811189-07	Jeremy Bingham	jeremy@goiardi.gl	2014-06-02 14:03:22-07	Jeremy Bingham	jbingham@gmail.com
revert	b8ef36df686397ecb0fe67eb097e84aa0d78ac6b	sandbox_insert_update	goiardi_postgres	Insert/update for sandboxes	{sandboxes,goiardi_schema}	{}	{}	2015-07-22 15:09:12.825233-07	Jeremy Bingham	jeremy@goiardi.gl	2014-06-02 10:34:39-07	Jeremy Bingham	jbingham@gmail.com
revert	acf76029633d50febbec7c4763b7173078eddaf7	role_insert_update	goiardi_postgres	Insert/update for roles	{roles,goiardi_schema}	{}	{}	2015-07-22 15:09:12.837906-07	Jeremy Bingham	jeremy@goiardi.gl	2014-06-02 10:27:32-07	Jeremy Bingham	jbingham@gmail.com
revert	d052a8267a6512581e5cab1f89a2456f279727b9	report_insert_update	goiardi_postgres	Insert/update for reports	{reports,goiardi_schema}	{}	{}	2015-07-22 15:09:12.851764-07	Jeremy Bingham	jeremy@goiardi.gl	2014-06-02 10:10:25-07	Jeremy Bingham	jbingham@gmail.com
revert	82a95e5e6cbd8ba51fea33506e1edb2a12e37a92	node_insert_update	goiardi_postgres	Insert/update for nodes	{nodes,goiardi_schema}	{}	{}	2015-07-22 15:09:12.864301-07	Jeremy Bingham	jeremy@goiardi.gl	2014-06-01 23:25:20-07	Jeremy Bingham	jbingham@gmail.com
revert	6d9587fa4275827c93ca9d7e0166ad1887b76cad	file_checksum_insert_ignore	goiardi_postgres	Insert ignore for file checksums	{file_checksums,goiardi_schema}	{}	{}	2015-07-22 15:09:12.877718-07	Jeremy Bingham	jeremy@goiardi.gl	2014-06-01 23:13:48-07	Jeremy Bingham	jbingham@gmail.com
revert	092885e8b5d94a9c1834bf309e02dc0f955ff053	environment_insert_update	goiardi_postgres	Insert/update environments	{environments,goiardi_schema}	{}	{}	2015-07-22 15:09:12.890554-07	Jeremy Bingham	jeremy@goiardi.gl	2014-06-01 12:55:34-07	Jeremy Bingham	jbingham@gmail.com
revert	04bea39d649e4187d9579bd946fd60f760240d10	data_bag_insert_update	goiardi_postgres	Insert/update data bags	{data_bags,goiardi_schema}	{}	{}	2015-07-22 15:09:12.904035-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-31 23:25:44-07	Jeremy Bingham	jbingham@gmail.com
revert	085e2f6281914c9fa6521d59fea81f16c106b59f	cookbook_versions_insert_update	goiardi_postgres	Cookbook versions insert/update	{cookbook_versions,goiardi_schema}	{}	{}	2015-07-22 15:09:12.918625-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-30 23:56:05-07	Jeremy Bingham	jbingham@gmail.com
revert	841a7d554d44f9d0d0b8a1a5a9d0a06ce71a2453	cookbook_insert_update	goiardi_postgres	Cookbook insert/update	{cookbooks,goiardi_schema}	{}	{}	2015-07-22 15:09:12.933409-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-30 23:55:23-07	Jeremy Bingham	jbingham@gmail.com
revert	f336c149ab32530c9c6ae4408c11558a635f39a1	user_rename	goiardi_postgres	Function to rename users	{users,goiardi_schema}	{}	{}	2015-07-22 15:09:12.946921-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-30 13:15:45-07	Jeremy Bingham	jbingham@gmail.com
revert	2d1fdc8128b0632e798df7346e76f122ed5915ec	user_insert_duplicate	goiardi_postgres	Function to emulate insert ... on duplicate update for clients	{users,goiardi_schema}	{}	{}	2015-07-22 15:09:12.961315-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-30 13:07:46-07	Jeremy Bingham	jbingham@gmail.com
revert	30774a960a0efb6adfbb1d526b8cdb1a45c7d039	client_rename	goiardi_postgres	Function to rename clients	{clients,goiardi_schema}	{}	{}	2015-07-22 15:09:12.974506-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-30 10:22:50-07	Jeremy Bingham	jbingham@gmail.com
revert	c8b38382f7e5a18f36c621327f59205aa8aa9849	client_insert_duplicate	goiardi_postgres	Function to emulate insert ... on duplicate update for clients	{clients,goiardi_schema}	{}	{}	2015-07-22 15:09:12.987458-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 23:00:04-07	Jeremy Bingham	jbingham@gmail.com
revert	db1eb360cd5e6449a468ceb781d82b45dafb5c2d	reports	goiardi_postgres	Create reports table	{}	{}	{}	2015-07-22 15:09:13.005186-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 13:02:49-07	Jeremy Bingham	jbingham@gmail.com
revert	f2621482d1c130ea8fee15d09f966685409bf67c	file_checksums	goiardi_postgres	Create file checksums table	{}	{}	{}	2015-07-22 15:09:13.026555-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 12:49:19-07	Jeremy Bingham	jbingham@gmail.com
revert	fce5b7aeed2ad742de1309d7841577cff19475a7	organizations	goiardi_postgres	Create organizations table	{}	{}	{}	2015-07-22 15:09:13.047734-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 12:46:28-07	Jeremy Bingham	jbingham@gmail.com
revert	81003655b93b41359804027fc202788aa0ddd9a9	log_infos	goiardi_postgres	Create log_infos table	{clients,users,goiardi_schema}	{}	{}	2015-07-22 15:09:13.065364-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 12:19:10-07	Jeremy Bingham	jbingham@gmail.com
revert	c4b32778f2911930f583ce15267aade320ac4dcd	sandboxes	goiardi_postgres	Create sandboxes table	{goiardi_schema}	{}	{}	2015-07-22 15:09:13.082858-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 12:14:48-07	Jeremy Bingham	jbingham@gmail.com
revert	6a4489d9436ba1541d272700b303410cc906b08f	roles	goiardi_postgres	Create roles table	{goiardi_schema}	{}	{}	2015-07-22 15:09:13.100419-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 12:09:28-07	Jeremy Bingham	jbingham@gmail.com
revert	feddf91b62caed36c790988bd29222591980433b	data_bag_items	goiardi_postgres	Create data bag items table	{data_bags,goiardi_schema}	{}	{}	2015-07-22 15:09:13.117088-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 12:02:31-07	Jeremy Bingham	jbingham@gmail.com
revert	85483913f96710c1267c6abacb6568cef9327f15	data_bags	goiardi_postgres	Create cookbook data bags table	{goiardi_schema}	{}	{}	2015-07-22 15:09:13.135648-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 11:42:04-07	Jeremy Bingham	jbingham@gmail.com
revert	f529038064a0259bdecbdab1f9f665e17ddb6136	cookbook_versions	goiardi_postgres	Create cookbook versions table	{cookbooks,goiardi_schema}	{}	{}	2015-07-22 15:09:13.153472-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 11:31:34-07	Jeremy Bingham	jbingham@gmail.com
revert	138bc49d92c0bbb024cea41532a656f2d7f9b072	cookbooks	goiardi_postgres	Create cookbook  table	{goiardi_schema}	{}	{}	2015-07-22 15:09:13.171146-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 11:27:27-07	Jeremy Bingham	jbingham@gmail.com
revert	bb82d8869ffca8ba3d03a1502c50dbb3eee7a2e0	users	goiardi_postgres	Create user table	{goiardi_schema}	{}	{}	2015-07-22 15:09:13.187932-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 11:15:02-07	Jeremy Bingham	jbingham@gmail.com
revert	faa3571aa479de60f25785e707433b304ba3d2c7	clients	goiardi_postgres	Create client table	{goiardi_schema}	{}	{}	2015-07-22 15:09:13.205907-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 11:05:33-07	Jeremy Bingham	jbingham@gmail.com
revert	911c456769628c817340ee77fc8d2b7c1d697782	nodes	goiardi_postgres	Create node table	{goiardi_schema}	{}	{}	2015-07-22 15:09:13.222232-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 10:37:46-07	Jeremy Bingham	jbingham@gmail.com
revert	367c28670efddf25455b9fd33c23a5a278b08bb4	environments	goiardi_postgres	Environments for postgres	{goiardi_schema}	{}	{}	2015-07-22 15:09:13.242232-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 00:40:11-07	Jeremy Bingham	jbingham@gmail.com
revert	c89b0e25c808b327036c88e6c9750c7526314c86	goiardi_schema	goiardi_postgres	Add schema for goiardi-postgres	{}	{}	{}	2015-07-22 15:09:13.260386-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-27 14:09:07-07	Jeremy Bingham	jbingham@gmail.com
deploy	c89b0e25c808b327036c88e6c9750c7526314c86	goiardi_schema	goiardi_postgres	Add schema for goiardi-postgres	{}	{}	{}	2015-07-22 15:09:15.062477-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-27 14:09:07-07	Jeremy Bingham	jbingham@gmail.com
deploy	367c28670efddf25455b9fd33c23a5a278b08bb4	environments	goiardi_postgres	Environments for postgres	{goiardi_schema}	{}	{}	2015-07-22 15:09:15.084575-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 00:40:11-07	Jeremy Bingham	jbingham@gmail.com
deploy	911c456769628c817340ee77fc8d2b7c1d697782	nodes	goiardi_postgres	Create node table	{goiardi_schema}	{}	{}	2015-07-22 15:09:15.104801-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 10:37:46-07	Jeremy Bingham	jbingham@gmail.com
deploy	faa3571aa479de60f25785e707433b304ba3d2c7	clients	goiardi_postgres	Create client table	{goiardi_schema}	{}	{}	2015-07-22 15:09:15.123749-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 11:05:33-07	Jeremy Bingham	jbingham@gmail.com
deploy	bb82d8869ffca8ba3d03a1502c50dbb3eee7a2e0	users	goiardi_postgres	Create user table	{goiardi_schema}	{}	{}	2015-07-22 15:09:15.142876-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 11:15:02-07	Jeremy Bingham	jbingham@gmail.com
deploy	138bc49d92c0bbb024cea41532a656f2d7f9b072	cookbooks	goiardi_postgres	Create cookbook  table	{goiardi_schema}	{}	{}	2015-07-22 15:09:15.1642-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 11:27:27-07	Jeremy Bingham	jbingham@gmail.com
deploy	f529038064a0259bdecbdab1f9f665e17ddb6136	cookbook_versions	goiardi_postgres	Create cookbook versions table	{cookbooks,goiardi_schema}	{}	{}	2015-07-22 15:09:15.185802-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 11:31:34-07	Jeremy Bingham	jbingham@gmail.com
deploy	85483913f96710c1267c6abacb6568cef9327f15	data_bags	goiardi_postgres	Create cookbook data bags table	{goiardi_schema}	{}	{}	2015-07-22 15:09:15.204536-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 11:42:04-07	Jeremy Bingham	jbingham@gmail.com
deploy	feddf91b62caed36c790988bd29222591980433b	data_bag_items	goiardi_postgres	Create data bag items table	{data_bags,goiardi_schema}	{}	{}	2015-07-22 15:09:15.224361-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 12:02:31-07	Jeremy Bingham	jbingham@gmail.com
deploy	6a4489d9436ba1541d272700b303410cc906b08f	roles	goiardi_postgres	Create roles table	{goiardi_schema}	{}	{}	2015-07-22 15:09:15.244987-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 12:09:28-07	Jeremy Bingham	jbingham@gmail.com
deploy	c4b32778f2911930f583ce15267aade320ac4dcd	sandboxes	goiardi_postgres	Create sandboxes table	{goiardi_schema}	{}	{}	2015-07-22 15:09:15.272172-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 12:14:48-07	Jeremy Bingham	jbingham@gmail.com
deploy	81003655b93b41359804027fc202788aa0ddd9a9	log_infos	goiardi_postgres	Create log_infos table	{clients,users,goiardi_schema}	{}	{}	2015-07-22 15:09:15.296967-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 12:19:10-07	Jeremy Bingham	jbingham@gmail.com
deploy	fce5b7aeed2ad742de1309d7841577cff19475a7	organizations	goiardi_postgres	Create organizations table	{}	{}	{}	2015-07-22 15:09:15.316768-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 12:46:28-07	Jeremy Bingham	jbingham@gmail.com
deploy	f2621482d1c130ea8fee15d09f966685409bf67c	file_checksums	goiardi_postgres	Create file checksums table	{}	{}	{}	2015-07-22 15:09:15.335057-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 12:49:19-07	Jeremy Bingham	jbingham@gmail.com
deploy	db1eb360cd5e6449a468ceb781d82b45dafb5c2d	reports	goiardi_postgres	Create reports table	{}	{}	{}	2015-07-22 15:09:15.35737-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 13:02:49-07	Jeremy Bingham	jbingham@gmail.com
deploy	c8b38382f7e5a18f36c621327f59205aa8aa9849	client_insert_duplicate	goiardi_postgres	Function to emulate insert ... on duplicate update for clients	{clients,goiardi_schema}	{}	{}	2015-07-22 15:09:15.373191-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 23:00:04-07	Jeremy Bingham	jbingham@gmail.com
deploy	30774a960a0efb6adfbb1d526b8cdb1a45c7d039	client_rename	goiardi_postgres	Function to rename clients	{clients,goiardi_schema}	{}	{}	2015-07-22 15:09:15.388161-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-30 10:22:50-07	Jeremy Bingham	jbingham@gmail.com
deploy	2d1fdc8128b0632e798df7346e76f122ed5915ec	user_insert_duplicate	goiardi_postgres	Function to emulate insert ... on duplicate update for clients	{users,goiardi_schema}	{}	{}	2015-07-22 15:09:15.403288-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-30 13:07:46-07	Jeremy Bingham	jbingham@gmail.com
deploy	f336c149ab32530c9c6ae4408c11558a635f39a1	user_rename	goiardi_postgres	Function to rename users	{users,goiardi_schema}	{}	{}	2015-07-22 15:09:15.419108-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-30 13:15:45-07	Jeremy Bingham	jbingham@gmail.com
deploy	841a7d554d44f9d0d0b8a1a5a9d0a06ce71a2453	cookbook_insert_update	goiardi_postgres	Cookbook insert/update	{cookbooks,goiardi_schema}	{}	{}	2015-07-22 15:09:15.435531-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-30 23:55:23-07	Jeremy Bingham	jbingham@gmail.com
deploy	085e2f6281914c9fa6521d59fea81f16c106b59f	cookbook_versions_insert_update	goiardi_postgres	Cookbook versions insert/update	{cookbook_versions,goiardi_schema}	{}	{}	2015-07-22 15:09:15.451161-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-30 23:56:05-07	Jeremy Bingham	jbingham@gmail.com
deploy	04bea39d649e4187d9579bd946fd60f760240d10	data_bag_insert_update	goiardi_postgres	Insert/update data bags	{data_bags,goiardi_schema}	{}	{}	2015-07-22 15:09:15.466363-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-31 23:25:44-07	Jeremy Bingham	jbingham@gmail.com
deploy	092885e8b5d94a9c1834bf309e02dc0f955ff053	environment_insert_update	goiardi_postgres	Insert/update environments	{environments,goiardi_schema}	{}	{}	2015-07-22 15:09:15.48085-07	Jeremy Bingham	jeremy@goiardi.gl	2014-06-01 12:55:34-07	Jeremy Bingham	jbingham@gmail.com
deploy	6d9587fa4275827c93ca9d7e0166ad1887b76cad	file_checksum_insert_ignore	goiardi_postgres	Insert ignore for file checksums	{file_checksums,goiardi_schema}	{}	{}	2015-07-22 15:09:15.50237-07	Jeremy Bingham	jeremy@goiardi.gl	2014-06-01 23:13:48-07	Jeremy Bingham	jbingham@gmail.com
deploy	82a95e5e6cbd8ba51fea33506e1edb2a12e37a92	node_insert_update	goiardi_postgres	Insert/update for nodes	{nodes,goiardi_schema}	{}	{}	2015-07-22 15:09:15.524718-07	Jeremy Bingham	jeremy@goiardi.gl	2014-06-01 23:25:20-07	Jeremy Bingham	jbingham@gmail.com
deploy	d052a8267a6512581e5cab1f89a2456f279727b9	report_insert_update	goiardi_postgres	Insert/update for reports	{reports,goiardi_schema}	{}	{}	2015-07-22 15:09:15.540144-07	Jeremy Bingham	jeremy@goiardi.gl	2014-06-02 10:10:25-07	Jeremy Bingham	jbingham@gmail.com
deploy	acf76029633d50febbec7c4763b7173078eddaf7	role_insert_update	goiardi_postgres	Insert/update for roles	{roles,goiardi_schema}	{}	{}	2015-07-22 15:09:15.555493-07	Jeremy Bingham	jeremy@goiardi.gl	2014-06-02 10:27:32-07	Jeremy Bingham	jbingham@gmail.com
deploy	b8ef36df686397ecb0fe67eb097e84aa0d78ac6b	sandbox_insert_update	goiardi_postgres	Insert/update for sandboxes	{sandboxes,goiardi_schema}	{}	{}	2015-07-22 15:09:15.570915-07	Jeremy Bingham	jeremy@goiardi.gl	2014-06-02 10:34:39-07	Jeremy Bingham	jbingham@gmail.com
deploy	93dbbda50a25da0a586e89ccee8fcfa2ddcb7c64	data_bag_item_insert	goiardi_postgres	Insert for data bag items	{data_bag_items,data_bags,goiardi_schema}	{}	{@v0.6.0}	2015-07-22 15:09:15.587918-07	Jeremy Bingham	jeremy@goiardi.gl	2014-06-02 14:03:22-07	Jeremy Bingham	jbingham@gmail.com
deploy	c80c561c22f6e139165cdb338c7ce6fff8ff268d	bytea_to_json	goiardi_postgres	Change most postgres bytea fields to json, because in this peculiar case json is way faster than gob	{}	{}	{}	2015-07-22 15:09:15.650039-07	Jeremy Bingham	jeremy@goiardi.gl	2014-07-20 02:41:22-07	Jeremy Bingham	jbingham@gmail.com
deploy	9966894e0fc0da573243f6a3c0fc1432a2b63043	joined_cookbkook_version	goiardi_postgres	a convenient view for joined versions for cookbook versions, adapted from erchef's joined_cookbook_version	{}	{}	{@v0.7.0}	2015-07-22 15:09:15.667809-07	Jeremy Bingham	jeremy@goiardi.gl	2014-07-20 03:21:28-07	Jeremy Bingham	jbingham@gmail.com
deploy	163ba4a496b9b4210d335e0e4ea5368a9ea8626c	node_statuses	goiardi_postgres	Create node_status table for node statuses	{nodes}	{}	{}	2015-07-22 15:09:15.688155-07	Jeremy Bingham	jeremy@goiardi.gl	2014-07-10 23:01:54-07	Jeremy Bingham	jeremy@terqa.local
deploy	8bb822f391b499585cfb2fc7248be469b0200682	node_status_insert	goiardi_postgres	insert function for node_statuses	{node_statuses}	{}	{}	2015-07-22 15:09:15.706612-07	Jeremy Bingham	jeremy@goiardi.gl	2014-07-11 00:01:31-07	Jeremy Bingham	jeremy@terqa.local
deploy	7c429aac08527adc774767584201f668408b04a6	add_down_column_nodes	goiardi_postgres	Add is_down column to the nodes table	{nodes}	{}	{}	2015-07-22 15:09:15.736679-07	Jeremy Bingham	jeremy@goiardi.gl	2014-07-15 20:18:05-07	Jeremy Bingham	jbingham@gmail.com
deploy	82bcace325dbdc905eb6e677f800d14a0506a216	shovey	goiardi_postgres	add shovey tables	{}	{}	{}	2015-07-22 15:09:15.769936-07	Jeremy Bingham	jeremy@goiardi.gl	2014-07-15 22:07:12-07	Jeremy Bingham	jeremy@terqa.local
deploy	62046d2fb96bbaedce2406252d312766452551c0	node_latest_statuses	goiardi_postgres	Add a view to easily get nodes by their latest status	{node_statuses}	{}	{}	2015-07-22 15:09:15.786368-07	Jeremy Bingham	jeremy@goiardi.gl	2014-07-26 13:32:02-07	Jeremy Bingham	jbingham@gmail.com
deploy	68f90e1fd2aac6a117d7697626741a02b8d0ebbe	shovey_insert_update	goiardi_postgres	insert/update functions for shovey	{shovey}	{}	{@v0.8.0}	2015-07-22 15:09:15.802519-07	Jeremy Bingham	jeremy@goiardi.gl	2014-08-27 00:46:20-07	Jeremy Bingham	jbingham@gmail.com
deploy	6f7aa2430e01cf33715828f1957d072cd5006d1c	ltree	goiardi_postgres	Add tables for ltree search for postgres	{}	{}	{}	2015-07-22 15:09:15.856407-07	Jeremy Bingham	jeremy@goiardi.gl	2015-04-10 23:21:26-07	Jeremy Bingham	jeremy@goiardi.gl
deploy	e7eb33b00d2fb6302e0c3979e9cac6fb80da377e	ltree_del_col	goiardi_postgres	procedure for deleting search collections	{}	{}	{}	2015-07-22 15:09:15.876624-07	Jeremy Bingham	jeremy@goiardi.gl	2015-04-12 12:33:15-07	Jeremy Bingham	jeremy@goiardi.gl
deploy	f49decbb15053ec5691093568450f642578ca460	ltree_del_item	goiardi_postgres	procedure for deleting search items	{}	{}	{}	2015-07-22 15:09:15.892877-07	Jeremy Bingham	jeremy@goiardi.gl	2015-04-12 13:03:50-07	Jeremy Bingham	jeremy@goiardi.gl
revert	e7eb33b00d2fb6302e0c3979e9cac6fb80da377e	ltree_del_col	goiardi_postgres	procedure for deleting search collections	{}	{}	{}	2015-07-22 15:16:13.971185-07	Jeremy Bingham	jeremy@goiardi.gl	2015-04-12 12:33:15-07	Jeremy Bingham	jeremy@goiardi.gl
revert	6f7aa2430e01cf33715828f1957d072cd5006d1c	ltree	goiardi_postgres	Add tables for ltree search for postgres	{}	{}	{}	2015-07-22 15:16:14.003587-07	Jeremy Bingham	jeremy@goiardi.gl	2015-04-10 23:21:26-07	Jeremy Bingham	jeremy@goiardi.gl
revert	68f90e1fd2aac6a117d7697626741a02b8d0ebbe	shovey_insert_update	goiardi_postgres	insert/update functions for shovey	{shovey}	{}	{@v0.8.0}	2015-07-22 15:16:14.018386-07	Jeremy Bingham	jeremy@goiardi.gl	2014-08-27 00:46:20-07	Jeremy Bingham	jbingham@gmail.com
revert	62046d2fb96bbaedce2406252d312766452551c0	node_latest_statuses	goiardi_postgres	Add a view to easily get nodes by their latest status	{node_statuses}	{}	{}	2015-07-22 15:16:14.031642-07	Jeremy Bingham	jeremy@goiardi.gl	2014-07-26 13:32:02-07	Jeremy Bingham	jbingham@gmail.com
revert	82bcace325dbdc905eb6e677f800d14a0506a216	shovey	goiardi_postgres	add shovey tables	{}	{}	{}	2015-07-22 15:16:14.052894-07	Jeremy Bingham	jeremy@goiardi.gl	2014-07-15 22:07:12-07	Jeremy Bingham	jeremy@terqa.local
revert	7c429aac08527adc774767584201f668408b04a6	add_down_column_nodes	goiardi_postgres	Add is_down column to the nodes table	{nodes}	{}	{}	2015-07-22 15:16:14.069032-07	Jeremy Bingham	jeremy@goiardi.gl	2014-07-15 20:18:05-07	Jeremy Bingham	jbingham@gmail.com
revert	8bb822f391b499585cfb2fc7248be469b0200682	node_status_insert	goiardi_postgres	insert function for node_statuses	{node_statuses}	{}	{}	2015-07-22 15:16:14.082259-07	Jeremy Bingham	jeremy@goiardi.gl	2014-07-11 00:01:31-07	Jeremy Bingham	jeremy@terqa.local
revert	163ba4a496b9b4210d335e0e4ea5368a9ea8626c	node_statuses	goiardi_postgres	Create node_status table for node statuses	{nodes}	{}	{}	2015-07-22 15:16:14.099695-07	Jeremy Bingham	jeremy@goiardi.gl	2014-07-10 23:01:54-07	Jeremy Bingham	jeremy@terqa.local
revert	9966894e0fc0da573243f6a3c0fc1432a2b63043	joined_cookbkook_version	goiardi_postgres	a convenient view for joined versions for cookbook versions, adapted from erchef's joined_cookbook_version	{}	{}	{@v0.7.0}	2015-07-22 15:16:14.112897-07	Jeremy Bingham	jeremy@goiardi.gl	2014-07-20 03:21:28-07	Jeremy Bingham	jbingham@gmail.com
revert	c80c561c22f6e139165cdb338c7ce6fff8ff268d	bytea_to_json	goiardi_postgres	Change most postgres bytea fields to json, because in this peculiar case json is way faster than gob	{}	{}	{}	2015-07-22 15:16:14.176242-07	Jeremy Bingham	jeremy@goiardi.gl	2014-07-20 02:41:22-07	Jeremy Bingham	jbingham@gmail.com
revert	93dbbda50a25da0a586e89ccee8fcfa2ddcb7c64	data_bag_item_insert	goiardi_postgres	Insert for data bag items	{data_bag_items,data_bags,goiardi_schema}	{}	{@v0.6.0}	2015-07-22 15:16:14.191183-07	Jeremy Bingham	jeremy@goiardi.gl	2014-06-02 14:03:22-07	Jeremy Bingham	jbingham@gmail.com
revert	b8ef36df686397ecb0fe67eb097e84aa0d78ac6b	sandbox_insert_update	goiardi_postgres	Insert/update for sandboxes	{sandboxes,goiardi_schema}	{}	{}	2015-07-22 15:16:14.208894-07	Jeremy Bingham	jeremy@goiardi.gl	2014-06-02 10:34:39-07	Jeremy Bingham	jbingham@gmail.com
revert	acf76029633d50febbec7c4763b7173078eddaf7	role_insert_update	goiardi_postgres	Insert/update for roles	{roles,goiardi_schema}	{}	{}	2015-07-22 15:16:14.222393-07	Jeremy Bingham	jeremy@goiardi.gl	2014-06-02 10:27:32-07	Jeremy Bingham	jbingham@gmail.com
revert	d052a8267a6512581e5cab1f89a2456f279727b9	report_insert_update	goiardi_postgres	Insert/update for reports	{reports,goiardi_schema}	{}	{}	2015-07-22 15:16:14.235405-07	Jeremy Bingham	jeremy@goiardi.gl	2014-06-02 10:10:25-07	Jeremy Bingham	jbingham@gmail.com
revert	82a95e5e6cbd8ba51fea33506e1edb2a12e37a92	node_insert_update	goiardi_postgres	Insert/update for nodes	{nodes,goiardi_schema}	{}	{}	2015-07-22 15:16:14.249907-07	Jeremy Bingham	jeremy@goiardi.gl	2014-06-01 23:25:20-07	Jeremy Bingham	jbingham@gmail.com
revert	6d9587fa4275827c93ca9d7e0166ad1887b76cad	file_checksum_insert_ignore	goiardi_postgres	Insert ignore for file checksums	{file_checksums,goiardi_schema}	{}	{}	2015-07-22 15:16:14.263807-07	Jeremy Bingham	jeremy@goiardi.gl	2014-06-01 23:13:48-07	Jeremy Bingham	jbingham@gmail.com
revert	092885e8b5d94a9c1834bf309e02dc0f955ff053	environment_insert_update	goiardi_postgres	Insert/update environments	{environments,goiardi_schema}	{}	{}	2015-07-22 15:16:14.277065-07	Jeremy Bingham	jeremy@goiardi.gl	2014-06-01 12:55:34-07	Jeremy Bingham	jbingham@gmail.com
revert	04bea39d649e4187d9579bd946fd60f760240d10	data_bag_insert_update	goiardi_postgres	Insert/update data bags	{data_bags,goiardi_schema}	{}	{}	2015-07-22 15:16:14.2906-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-31 23:25:44-07	Jeremy Bingham	jbingham@gmail.com
revert	085e2f6281914c9fa6521d59fea81f16c106b59f	cookbook_versions_insert_update	goiardi_postgres	Cookbook versions insert/update	{cookbook_versions,goiardi_schema}	{}	{}	2015-07-22 15:16:14.305058-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-30 23:56:05-07	Jeremy Bingham	jbingham@gmail.com
revert	841a7d554d44f9d0d0b8a1a5a9d0a06ce71a2453	cookbook_insert_update	goiardi_postgres	Cookbook insert/update	{cookbooks,goiardi_schema}	{}	{}	2015-07-22 15:16:14.317998-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-30 23:55:23-07	Jeremy Bingham	jbingham@gmail.com
revert	f336c149ab32530c9c6ae4408c11558a635f39a1	user_rename	goiardi_postgres	Function to rename users	{users,goiardi_schema}	{}	{}	2015-07-22 15:16:14.331516-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-30 13:15:45-07	Jeremy Bingham	jbingham@gmail.com
revert	2d1fdc8128b0632e798df7346e76f122ed5915ec	user_insert_duplicate	goiardi_postgres	Function to emulate insert ... on duplicate update for clients	{users,goiardi_schema}	{}	{}	2015-07-22 15:16:14.346001-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-30 13:07:46-07	Jeremy Bingham	jbingham@gmail.com
revert	30774a960a0efb6adfbb1d526b8cdb1a45c7d039	client_rename	goiardi_postgres	Function to rename clients	{clients,goiardi_schema}	{}	{}	2015-07-22 15:16:14.359383-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-30 10:22:50-07	Jeremy Bingham	jbingham@gmail.com
revert	c8b38382f7e5a18f36c621327f59205aa8aa9849	client_insert_duplicate	goiardi_postgres	Function to emulate insert ... on duplicate update for clients	{clients,goiardi_schema}	{}	{}	2015-07-22 15:16:14.371869-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 23:00:04-07	Jeremy Bingham	jbingham@gmail.com
revert	db1eb360cd5e6449a468ceb781d82b45dafb5c2d	reports	goiardi_postgres	Create reports table	{}	{}	{}	2015-07-22 15:16:14.389564-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 13:02:49-07	Jeremy Bingham	jbingham@gmail.com
revert	f2621482d1c130ea8fee15d09f966685409bf67c	file_checksums	goiardi_postgres	Create file checksums table	{}	{}	{}	2015-07-22 15:16:14.405736-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 12:49:19-07	Jeremy Bingham	jbingham@gmail.com
revert	fce5b7aeed2ad742de1309d7841577cff19475a7	organizations	goiardi_postgres	Create organizations table	{}	{}	{}	2015-07-22 15:16:14.423349-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 12:46:28-07	Jeremy Bingham	jbingham@gmail.com
revert	81003655b93b41359804027fc202788aa0ddd9a9	log_infos	goiardi_postgres	Create log_infos table	{clients,users,goiardi_schema}	{}	{}	2015-07-22 15:16:14.442221-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 12:19:10-07	Jeremy Bingham	jbingham@gmail.com
revert	c4b32778f2911930f583ce15267aade320ac4dcd	sandboxes	goiardi_postgres	Create sandboxes table	{goiardi_schema}	{}	{}	2015-07-22 15:16:14.459589-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 12:14:48-07	Jeremy Bingham	jbingham@gmail.com
revert	6a4489d9436ba1541d272700b303410cc906b08f	roles	goiardi_postgres	Create roles table	{goiardi_schema}	{}	{}	2015-07-22 15:16:14.478858-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 12:09:28-07	Jeremy Bingham	jbingham@gmail.com
revert	feddf91b62caed36c790988bd29222591980433b	data_bag_items	goiardi_postgres	Create data bag items table	{data_bags,goiardi_schema}	{}	{}	2015-07-22 15:16:14.49637-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 12:02:31-07	Jeremy Bingham	jbingham@gmail.com
revert	85483913f96710c1267c6abacb6568cef9327f15	data_bags	goiardi_postgres	Create cookbook data bags table	{goiardi_schema}	{}	{}	2015-07-22 15:16:14.513815-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 11:42:04-07	Jeremy Bingham	jbingham@gmail.com
revert	f529038064a0259bdecbdab1f9f665e17ddb6136	cookbook_versions	goiardi_postgres	Create cookbook versions table	{cookbooks,goiardi_schema}	{}	{}	2015-07-22 15:16:14.531262-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 11:31:34-07	Jeremy Bingham	jbingham@gmail.com
revert	138bc49d92c0bbb024cea41532a656f2d7f9b072	cookbooks	goiardi_postgres	Create cookbook  table	{goiardi_schema}	{}	{}	2015-07-22 15:16:14.548035-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 11:27:27-07	Jeremy Bingham	jbingham@gmail.com
revert	bb82d8869ffca8ba3d03a1502c50dbb3eee7a2e0	users	goiardi_postgres	Create user table	{goiardi_schema}	{}	{}	2015-07-22 15:16:14.570108-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 11:15:02-07	Jeremy Bingham	jbingham@gmail.com
revert	faa3571aa479de60f25785e707433b304ba3d2c7	clients	goiardi_postgres	Create client table	{goiardi_schema}	{}	{}	2015-07-22 15:16:14.593746-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 11:05:33-07	Jeremy Bingham	jbingham@gmail.com
revert	911c456769628c817340ee77fc8d2b7c1d697782	nodes	goiardi_postgres	Create node table	{goiardi_schema}	{}	{}	2015-07-22 15:16:14.611276-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 10:37:46-07	Jeremy Bingham	jbingham@gmail.com
revert	367c28670efddf25455b9fd33c23a5a278b08bb4	environments	goiardi_postgres	Environments for postgres	{goiardi_schema}	{}	{}	2015-07-22 15:16:14.62868-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 00:40:11-07	Jeremy Bingham	jbingham@gmail.com
revert	c89b0e25c808b327036c88e6c9750c7526314c86	goiardi_schema	goiardi_postgres	Add schema for goiardi-postgres	{}	{}	{}	2015-07-22 15:16:14.643395-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-27 14:09:07-07	Jeremy Bingham	jbingham@gmail.com
deploy	c89b0e25c808b327036c88e6c9750c7526314c86	goiardi_schema	goiardi_postgres	Add schema for goiardi-postgres	{}	{}	{}	2015-07-22 15:16:16.17466-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-27 14:09:07-07	Jeremy Bingham	jbingham@gmail.com
deploy	367c28670efddf25455b9fd33c23a5a278b08bb4	environments	goiardi_postgres	Environments for postgres	{goiardi_schema}	{}	{}	2015-07-22 15:16:16.194904-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 00:40:11-07	Jeremy Bingham	jbingham@gmail.com
deploy	911c456769628c817340ee77fc8d2b7c1d697782	nodes	goiardi_postgres	Create node table	{goiardi_schema}	{}	{}	2015-07-22 15:16:16.217861-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 10:37:46-07	Jeremy Bingham	jbingham@gmail.com
deploy	faa3571aa479de60f25785e707433b304ba3d2c7	clients	goiardi_postgres	Create client table	{goiardi_schema}	{}	{}	2015-07-22 15:16:16.235761-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 11:05:33-07	Jeremy Bingham	jbingham@gmail.com
deploy	bb82d8869ffca8ba3d03a1502c50dbb3eee7a2e0	users	goiardi_postgres	Create user table	{goiardi_schema}	{}	{}	2015-07-22 15:16:16.254689-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 11:15:02-07	Jeremy Bingham	jbingham@gmail.com
deploy	138bc49d92c0bbb024cea41532a656f2d7f9b072	cookbooks	goiardi_postgres	Create cookbook  table	{goiardi_schema}	{}	{}	2015-07-22 15:16:16.273673-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 11:27:27-07	Jeremy Bingham	jbingham@gmail.com
deploy	f529038064a0259bdecbdab1f9f665e17ddb6136	cookbook_versions	goiardi_postgres	Create cookbook versions table	{cookbooks,goiardi_schema}	{}	{}	2015-07-22 15:16:16.368827-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 11:31:34-07	Jeremy Bingham	jbingham@gmail.com
deploy	85483913f96710c1267c6abacb6568cef9327f15	data_bags	goiardi_postgres	Create cookbook data bags table	{goiardi_schema}	{}	{}	2015-07-22 15:16:16.387924-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 11:42:04-07	Jeremy Bingham	jbingham@gmail.com
deploy	feddf91b62caed36c790988bd29222591980433b	data_bag_items	goiardi_postgres	Create data bag items table	{data_bags,goiardi_schema}	{}	{}	2015-07-22 15:16:16.408219-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 12:02:31-07	Jeremy Bingham	jbingham@gmail.com
deploy	6a4489d9436ba1541d272700b303410cc906b08f	roles	goiardi_postgres	Create roles table	{goiardi_schema}	{}	{}	2015-07-22 15:16:16.435227-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 12:09:28-07	Jeremy Bingham	jbingham@gmail.com
deploy	c4b32778f2911930f583ce15267aade320ac4dcd	sandboxes	goiardi_postgres	Create sandboxes table	{goiardi_schema}	{}	{}	2015-07-22 15:16:16.45415-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 12:14:48-07	Jeremy Bingham	jbingham@gmail.com
deploy	81003655b93b41359804027fc202788aa0ddd9a9	log_infos	goiardi_postgres	Create log_infos table	{clients,users,goiardi_schema}	{}	{}	2015-07-22 15:16:16.502189-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 12:19:10-07	Jeremy Bingham	jbingham@gmail.com
deploy	fce5b7aeed2ad742de1309d7841577cff19475a7	organizations	goiardi_postgres	Create organizations table	{}	{}	{}	2015-07-22 15:16:16.525649-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 12:46:28-07	Jeremy Bingham	jbingham@gmail.com
deploy	f2621482d1c130ea8fee15d09f966685409bf67c	file_checksums	goiardi_postgres	Create file checksums table	{}	{}	{}	2015-07-22 15:16:16.543141-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 12:49:19-07	Jeremy Bingham	jbingham@gmail.com
deploy	db1eb360cd5e6449a468ceb781d82b45dafb5c2d	reports	goiardi_postgres	Create reports table	{}	{}	{}	2015-07-22 15:16:16.563596-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 13:02:49-07	Jeremy Bingham	jbingham@gmail.com
deploy	c8b38382f7e5a18f36c621327f59205aa8aa9849	client_insert_duplicate	goiardi_postgres	Function to emulate insert ... on duplicate update for clients	{clients,goiardi_schema}	{}	{}	2015-07-22 15:16:16.579044-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 23:00:04-07	Jeremy Bingham	jbingham@gmail.com
deploy	30774a960a0efb6adfbb1d526b8cdb1a45c7d039	client_rename	goiardi_postgres	Function to rename clients	{clients,goiardi_schema}	{}	{}	2015-07-22 15:16:16.594078-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-30 10:22:50-07	Jeremy Bingham	jbingham@gmail.com
deploy	2d1fdc8128b0632e798df7346e76f122ed5915ec	user_insert_duplicate	goiardi_postgres	Function to emulate insert ... on duplicate update for clients	{users,goiardi_schema}	{}	{}	2015-07-22 15:16:16.608351-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-30 13:07:46-07	Jeremy Bingham	jbingham@gmail.com
deploy	f336c149ab32530c9c6ae4408c11558a635f39a1	user_rename	goiardi_postgres	Function to rename users	{users,goiardi_schema}	{}	{}	2015-07-22 15:16:16.623618-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-30 13:15:45-07	Jeremy Bingham	jbingham@gmail.com
deploy	841a7d554d44f9d0d0b8a1a5a9d0a06ce71a2453	cookbook_insert_update	goiardi_postgres	Cookbook insert/update	{cookbooks,goiardi_schema}	{}	{}	2015-07-22 15:16:16.637644-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-30 23:55:23-07	Jeremy Bingham	jbingham@gmail.com
deploy	085e2f6281914c9fa6521d59fea81f16c106b59f	cookbook_versions_insert_update	goiardi_postgres	Cookbook versions insert/update	{cookbook_versions,goiardi_schema}	{}	{}	2015-07-22 15:16:16.653461-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-30 23:56:05-07	Jeremy Bingham	jbingham@gmail.com
deploy	04bea39d649e4187d9579bd946fd60f760240d10	data_bag_insert_update	goiardi_postgres	Insert/update data bags	{data_bags,goiardi_schema}	{}	{}	2015-07-22 15:16:16.668901-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-31 23:25:44-07	Jeremy Bingham	jbingham@gmail.com
deploy	092885e8b5d94a9c1834bf309e02dc0f955ff053	environment_insert_update	goiardi_postgres	Insert/update environments	{environments,goiardi_schema}	{}	{}	2015-07-22 15:16:16.683135-07	Jeremy Bingham	jeremy@goiardi.gl	2014-06-01 12:55:34-07	Jeremy Bingham	jbingham@gmail.com
deploy	6d9587fa4275827c93ca9d7e0166ad1887b76cad	file_checksum_insert_ignore	goiardi_postgres	Insert ignore for file checksums	{file_checksums,goiardi_schema}	{}	{}	2015-07-22 15:16:16.698838-07	Jeremy Bingham	jeremy@goiardi.gl	2014-06-01 23:13:48-07	Jeremy Bingham	jbingham@gmail.com
deploy	82a95e5e6cbd8ba51fea33506e1edb2a12e37a92	node_insert_update	goiardi_postgres	Insert/update for nodes	{nodes,goiardi_schema}	{}	{}	2015-07-22 15:16:16.714194-07	Jeremy Bingham	jeremy@goiardi.gl	2014-06-01 23:25:20-07	Jeremy Bingham	jbingham@gmail.com
deploy	d052a8267a6512581e5cab1f89a2456f279727b9	report_insert_update	goiardi_postgres	Insert/update for reports	{reports,goiardi_schema}	{}	{}	2015-07-22 15:16:16.728832-07	Jeremy Bingham	jeremy@goiardi.gl	2014-06-02 10:10:25-07	Jeremy Bingham	jbingham@gmail.com
deploy	acf76029633d50febbec7c4763b7173078eddaf7	role_insert_update	goiardi_postgres	Insert/update for roles	{roles,goiardi_schema}	{}	{}	2015-07-22 15:16:16.74384-07	Jeremy Bingham	jeremy@goiardi.gl	2014-06-02 10:27:32-07	Jeremy Bingham	jbingham@gmail.com
deploy	b8ef36df686397ecb0fe67eb097e84aa0d78ac6b	sandbox_insert_update	goiardi_postgres	Insert/update for sandboxes	{sandboxes,goiardi_schema}	{}	{}	2015-07-22 15:16:16.758891-07	Jeremy Bingham	jeremy@goiardi.gl	2014-06-02 10:34:39-07	Jeremy Bingham	jbingham@gmail.com
deploy	93dbbda50a25da0a586e89ccee8fcfa2ddcb7c64	data_bag_item_insert	goiardi_postgres	Insert for data bag items	{data_bag_items,data_bags,goiardi_schema}	{}	{@v0.6.0}	2015-07-22 15:16:16.774287-07	Jeremy Bingham	jeremy@goiardi.gl	2014-06-02 14:03:22-07	Jeremy Bingham	jbingham@gmail.com
deploy	c80c561c22f6e139165cdb338c7ce6fff8ff268d	bytea_to_json	goiardi_postgres	Change most postgres bytea fields to json, because in this peculiar case json is way faster than gob	{}	{}	{}	2015-07-22 15:16:16.825482-07	Jeremy Bingham	jeremy@goiardi.gl	2014-07-20 02:41:22-07	Jeremy Bingham	jbingham@gmail.com
deploy	9966894e0fc0da573243f6a3c0fc1432a2b63043	joined_cookbkook_version	goiardi_postgres	a convenient view for joined versions for cookbook versions, adapted from erchef's joined_cookbook_version	{}	{}	{@v0.7.0}	2015-07-22 15:16:16.845789-07	Jeremy Bingham	jeremy@goiardi.gl	2014-07-20 03:21:28-07	Jeremy Bingham	jbingham@gmail.com
deploy	163ba4a496b9b4210d335e0e4ea5368a9ea8626c	node_statuses	goiardi_postgres	Create node_status table for node statuses	{nodes}	{}	{}	2015-07-22 15:16:16.865016-07	Jeremy Bingham	jeremy@goiardi.gl	2014-07-10 23:01:54-07	Jeremy Bingham	jeremy@terqa.local
deploy	8bb822f391b499585cfb2fc7248be469b0200682	node_status_insert	goiardi_postgres	insert function for node_statuses	{node_statuses}	{}	{}	2015-07-22 15:16:16.882614-07	Jeremy Bingham	jeremy@goiardi.gl	2014-07-11 00:01:31-07	Jeremy Bingham	jeremy@terqa.local
deploy	7c429aac08527adc774767584201f668408b04a6	add_down_column_nodes	goiardi_postgres	Add is_down column to the nodes table	{nodes}	{}	{}	2015-07-22 15:16:16.911029-07	Jeremy Bingham	jeremy@goiardi.gl	2014-07-15 20:18:05-07	Jeremy Bingham	jbingham@gmail.com
deploy	82bcace325dbdc905eb6e677f800d14a0506a216	shovey	goiardi_postgres	add shovey tables	{}	{}	{}	2015-07-22 15:16:16.943203-07	Jeremy Bingham	jeremy@goiardi.gl	2014-07-15 22:07:12-07	Jeremy Bingham	jeremy@terqa.local
deploy	62046d2fb96bbaedce2406252d312766452551c0	node_latest_statuses	goiardi_postgres	Add a view to easily get nodes by their latest status	{node_statuses}	{}	{}	2015-07-22 15:16:16.959407-07	Jeremy Bingham	jeremy@goiardi.gl	2014-07-26 13:32:02-07	Jeremy Bingham	jbingham@gmail.com
deploy	68f90e1fd2aac6a117d7697626741a02b8d0ebbe	shovey_insert_update	goiardi_postgres	insert/update functions for shovey	{shovey}	{}	{@v0.8.0}	2015-07-22 15:16:16.975635-07	Jeremy Bingham	jeremy@goiardi.gl	2014-08-27 00:46:20-07	Jeremy Bingham	jbingham@gmail.com
deploy	6f7aa2430e01cf33715828f1957d072cd5006d1c	ltree	goiardi_postgres	Add tables for ltree search for postgres	{}	{}	{}	2015-07-22 15:16:17.025446-07	Jeremy Bingham	jeremy@goiardi.gl	2015-04-10 23:21:26-07	Jeremy Bingham	jeremy@goiardi.gl
deploy	e7eb33b00d2fb6302e0c3979e9cac6fb80da377e	ltree_del_col	goiardi_postgres	procedure for deleting search collections	{}	{}	{}	2015-07-22 15:16:17.045761-07	Jeremy Bingham	jeremy@goiardi.gl	2015-04-12 12:33:15-07	Jeremy Bingham	jeremy@goiardi.gl
deploy	f49decbb15053ec5691093568450f642578ca460	ltree_del_item	goiardi_postgres	procedure for deleting search items	{}	{}	{}	2015-07-22 15:16:17.060391-07	Jeremy Bingham	jeremy@goiardi.gl	2015-04-12 13:03:50-07	Jeremy Bingham	jeremy@goiardi.gl
revert	f49decbb15053ec5691093568450f642578ca460	ltree_del_item	goiardi_postgres	procedure for deleting search items	{}	{}	{}	2015-07-23 00:27:11.746007-07	Jeremy Bingham	jeremy@goiardi.gl	2015-04-12 13:03:50-07	Jeremy Bingham	jeremy@goiardi.gl
revert	e7eb33b00d2fb6302e0c3979e9cac6fb80da377e	ltree_del_col	goiardi_postgres	procedure for deleting search collections	{}	{}	{}	2015-07-23 00:27:11.761852-07	Jeremy Bingham	jeremy@goiardi.gl	2015-04-12 12:33:15-07	Jeremy Bingham	jeremy@goiardi.gl
revert	6f7aa2430e01cf33715828f1957d072cd5006d1c	ltree	goiardi_postgres	Add tables for ltree search for postgres	{}	{}	{}	2015-07-23 00:27:11.869977-07	Jeremy Bingham	jeremy@goiardi.gl	2015-04-10 23:21:26-07	Jeremy Bingham	jeremy@goiardi.gl
revert	68f90e1fd2aac6a117d7697626741a02b8d0ebbe	shovey_insert_update	goiardi_postgres	insert/update functions for shovey	{shovey}	{}	{@v0.8.0}	2015-07-23 00:27:11.884715-07	Jeremy Bingham	jeremy@goiardi.gl	2014-08-27 00:46:20-07	Jeremy Bingham	jbingham@gmail.com
revert	62046d2fb96bbaedce2406252d312766452551c0	node_latest_statuses	goiardi_postgres	Add a view to easily get nodes by their latest status	{node_statuses}	{}	{}	2015-07-23 00:27:11.899011-07	Jeremy Bingham	jeremy@goiardi.gl	2014-07-26 13:32:02-07	Jeremy Bingham	jbingham@gmail.com
revert	82bcace325dbdc905eb6e677f800d14a0506a216	shovey	goiardi_postgres	add shovey tables	{}	{}	{}	2015-07-23 00:27:11.957505-07	Jeremy Bingham	jeremy@goiardi.gl	2014-07-15 22:07:12-07	Jeremy Bingham	jeremy@terqa.local
revert	7c429aac08527adc774767584201f668408b04a6	add_down_column_nodes	goiardi_postgres	Add is_down column to the nodes table	{nodes}	{}	{}	2015-07-23 00:27:11.980254-07	Jeremy Bingham	jeremy@goiardi.gl	2014-07-15 20:18:05-07	Jeremy Bingham	jbingham@gmail.com
revert	8bb822f391b499585cfb2fc7248be469b0200682	node_status_insert	goiardi_postgres	insert function for node_statuses	{node_statuses}	{}	{}	2015-07-23 00:27:11.994619-07	Jeremy Bingham	jeremy@goiardi.gl	2014-07-11 00:01:31-07	Jeremy Bingham	jeremy@terqa.local
revert	163ba4a496b9b4210d335e0e4ea5368a9ea8626c	node_statuses	goiardi_postgres	Create node_status table for node statuses	{nodes}	{}	{}	2015-07-23 00:27:12.040728-07	Jeremy Bingham	jeremy@goiardi.gl	2014-07-10 23:01:54-07	Jeremy Bingham	jeremy@terqa.local
revert	9966894e0fc0da573243f6a3c0fc1432a2b63043	joined_cookbkook_version	goiardi_postgres	a convenient view for joined versions for cookbook versions, adapted from erchef's joined_cookbook_version	{}	{}	{@v0.7.0}	2015-07-23 00:27:12.058561-07	Jeremy Bingham	jeremy@goiardi.gl	2014-07-20 03:21:28-07	Jeremy Bingham	jbingham@gmail.com
revert	c80c561c22f6e139165cdb338c7ce6fff8ff268d	bytea_to_json	goiardi_postgres	Change most postgres bytea fields to json, because in this peculiar case json is way faster than gob	{}	{}	{}	2015-07-23 00:27:12.204533-07	Jeremy Bingham	jeremy@goiardi.gl	2014-07-20 02:41:22-07	Jeremy Bingham	jbingham@gmail.com
revert	93dbbda50a25da0a586e89ccee8fcfa2ddcb7c64	data_bag_item_insert	goiardi_postgres	Insert for data bag items	{data_bag_items,data_bags,goiardi_schema}	{}	{@v0.6.0}	2015-07-23 00:27:12.219837-07	Jeremy Bingham	jeremy@goiardi.gl	2014-06-02 14:03:22-07	Jeremy Bingham	jbingham@gmail.com
revert	b8ef36df686397ecb0fe67eb097e84aa0d78ac6b	sandbox_insert_update	goiardi_postgres	Insert/update for sandboxes	{sandboxes,goiardi_schema}	{}	{}	2015-07-23 00:27:12.234716-07	Jeremy Bingham	jeremy@goiardi.gl	2014-06-02 10:34:39-07	Jeremy Bingham	jbingham@gmail.com
revert	acf76029633d50febbec7c4763b7173078eddaf7	role_insert_update	goiardi_postgres	Insert/update for roles	{roles,goiardi_schema}	{}	{}	2015-07-23 00:27:12.248401-07	Jeremy Bingham	jeremy@goiardi.gl	2014-06-02 10:27:32-07	Jeremy Bingham	jbingham@gmail.com
revert	d052a8267a6512581e5cab1f89a2456f279727b9	report_insert_update	goiardi_postgres	Insert/update for reports	{reports,goiardi_schema}	{}	{}	2015-07-23 00:27:12.261079-07	Jeremy Bingham	jeremy@goiardi.gl	2014-06-02 10:10:25-07	Jeremy Bingham	jbingham@gmail.com
revert	82a95e5e6cbd8ba51fea33506e1edb2a12e37a92	node_insert_update	goiardi_postgres	Insert/update for nodes	{nodes,goiardi_schema}	{}	{}	2015-07-23 00:27:12.274433-07	Jeremy Bingham	jeremy@goiardi.gl	2014-06-01 23:25:20-07	Jeremy Bingham	jbingham@gmail.com
revert	6d9587fa4275827c93ca9d7e0166ad1887b76cad	file_checksum_insert_ignore	goiardi_postgres	Insert ignore for file checksums	{file_checksums,goiardi_schema}	{}	{}	2015-07-23 00:27:12.286958-07	Jeremy Bingham	jeremy@goiardi.gl	2014-06-01 23:13:48-07	Jeremy Bingham	jbingham@gmail.com
revert	092885e8b5d94a9c1834bf309e02dc0f955ff053	environment_insert_update	goiardi_postgres	Insert/update environments	{environments,goiardi_schema}	{}	{}	2015-07-23 00:27:12.301276-07	Jeremy Bingham	jeremy@goiardi.gl	2014-06-01 12:55:34-07	Jeremy Bingham	jbingham@gmail.com
revert	04bea39d649e4187d9579bd946fd60f760240d10	data_bag_insert_update	goiardi_postgres	Insert/update data bags	{data_bags,goiardi_schema}	{}	{}	2015-07-23 00:27:12.316596-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-31 23:25:44-07	Jeremy Bingham	jbingham@gmail.com
revert	085e2f6281914c9fa6521d59fea81f16c106b59f	cookbook_versions_insert_update	goiardi_postgres	Cookbook versions insert/update	{cookbook_versions,goiardi_schema}	{}	{}	2015-07-23 00:27:12.345253-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-30 23:56:05-07	Jeremy Bingham	jbingham@gmail.com
revert	841a7d554d44f9d0d0b8a1a5a9d0a06ce71a2453	cookbook_insert_update	goiardi_postgres	Cookbook insert/update	{cookbooks,goiardi_schema}	{}	{}	2015-07-23 00:27:12.36506-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-30 23:55:23-07	Jeremy Bingham	jbingham@gmail.com
revert	f336c149ab32530c9c6ae4408c11558a635f39a1	user_rename	goiardi_postgres	Function to rename users	{goiardi_schema,users}	{}	{}	2015-07-23 00:27:12.379583-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-30 13:15:45-07	Jeremy Bingham	jbingham@gmail.com
revert	2d1fdc8128b0632e798df7346e76f122ed5915ec	user_insert_duplicate	goiardi_postgres	Function to emulate insert ... on duplicate update for clients	{users,goiardi_schema}	{}	{}	2015-07-23 00:27:12.393548-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-30 13:07:46-07	Jeremy Bingham	jbingham@gmail.com
revert	30774a960a0efb6adfbb1d526b8cdb1a45c7d039	client_rename	goiardi_postgres	Function to rename clients	{clients,goiardi_schema}	{}	{}	2015-07-23 00:27:12.407816-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-30 10:22:50-07	Jeremy Bingham	jbingham@gmail.com
revert	c8b38382f7e5a18f36c621327f59205aa8aa9849	client_insert_duplicate	goiardi_postgres	Function to emulate insert ... on duplicate update for clients	{clients,goiardi_schema}	{}	{}	2015-07-23 00:27:12.423774-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 23:00:04-07	Jeremy Bingham	jbingham@gmail.com
revert	db1eb360cd5e6449a468ceb781d82b45dafb5c2d	reports	goiardi_postgres	Create reports table	{}	{}	{}	2015-07-23 00:27:12.442927-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 13:02:49-07	Jeremy Bingham	jbingham@gmail.com
revert	f2621482d1c130ea8fee15d09f966685409bf67c	file_checksums	goiardi_postgres	Create file checksums table	{}	{}	{}	2015-07-23 00:27:12.469693-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 12:49:19-07	Jeremy Bingham	jbingham@gmail.com
revert	fce5b7aeed2ad742de1309d7841577cff19475a7	organizations	goiardi_postgres	Create organizations table	{}	{}	{}	2015-07-23 00:27:12.495137-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 12:46:28-07	Jeremy Bingham	jbingham@gmail.com
revert	81003655b93b41359804027fc202788aa0ddd9a9	log_infos	goiardi_postgres	Create log_infos table	{clients,users,goiardi_schema}	{}	{}	2015-07-23 00:27:12.526095-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 12:19:10-07	Jeremy Bingham	jbingham@gmail.com
revert	c4b32778f2911930f583ce15267aade320ac4dcd	sandboxes	goiardi_postgres	Create sandboxes table	{goiardi_schema}	{}	{}	2015-07-23 00:27:12.544783-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 12:14:48-07	Jeremy Bingham	jbingham@gmail.com
revert	6a4489d9436ba1541d272700b303410cc906b08f	roles	goiardi_postgres	Create roles table	{goiardi_schema}	{}	{}	2015-07-23 00:27:12.563682-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 12:09:28-07	Jeremy Bingham	jbingham@gmail.com
revert	feddf91b62caed36c790988bd29222591980433b	data_bag_items	goiardi_postgres	Create data bag items table	{data_bags,goiardi_schema}	{}	{}	2015-07-23 00:27:12.582603-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 12:02:31-07	Jeremy Bingham	jbingham@gmail.com
revert	85483913f96710c1267c6abacb6568cef9327f15	data_bags	goiardi_postgres	Create cookbook data bags table	{goiardi_schema}	{}	{}	2015-07-23 00:27:12.610455-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 11:42:04-07	Jeremy Bingham	jbingham@gmail.com
revert	f529038064a0259bdecbdab1f9f665e17ddb6136	cookbook_versions	goiardi_postgres	Create cookbook versions table	{cookbooks,goiardi_schema}	{}	{}	2015-07-23 00:27:12.631087-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 11:31:34-07	Jeremy Bingham	jbingham@gmail.com
revert	138bc49d92c0bbb024cea41532a656f2d7f9b072	cookbooks	goiardi_postgres	Create cookbook  table	{goiardi_schema}	{}	{}	2015-07-23 00:27:12.661428-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 11:27:27-07	Jeremy Bingham	jbingham@gmail.com
revert	bb82d8869ffca8ba3d03a1502c50dbb3eee7a2e0	users	goiardi_postgres	Create user table	{goiardi_schema}	{}	{}	2015-07-23 00:27:12.690325-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 11:15:02-07	Jeremy Bingham	jbingham@gmail.com
revert	faa3571aa479de60f25785e707433b304ba3d2c7	clients	goiardi_postgres	Create client table	{goiardi_schema}	{}	{}	2015-07-23 00:27:12.718519-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 11:05:33-07	Jeremy Bingham	jbingham@gmail.com
revert	911c456769628c817340ee77fc8d2b7c1d697782	nodes	goiardi_postgres	Create node table	{goiardi_schema}	{}	{}	2015-07-23 00:27:12.737077-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 10:37:46-07	Jeremy Bingham	jbingham@gmail.com
revert	367c28670efddf25455b9fd33c23a5a278b08bb4	environments	goiardi_postgres	Environments for postgres	{goiardi_schema}	{}	{}	2015-07-23 00:27:12.756298-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 00:40:11-07	Jeremy Bingham	jbingham@gmail.com
revert	c89b0e25c808b327036c88e6c9750c7526314c86	goiardi_schema	goiardi_postgres	Add schema for goiardi-postgres	{}	{}	{}	2015-07-23 00:27:12.769865-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-27 14:09:07-07	Jeremy Bingham	jbingham@gmail.com
deploy	c89b0e25c808b327036c88e6c9750c7526314c86	goiardi_schema	goiardi_postgres	Add schema for goiardi-postgres	{}	{}	{}	2015-07-23 00:27:18.483843-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-27 14:09:07-07	Jeremy Bingham	jbingham@gmail.com
deploy	367c28670efddf25455b9fd33c23a5a278b08bb4	environments	goiardi_postgres	Environments for postgres	{goiardi_schema}	{}	{}	2015-07-23 00:27:18.505715-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 00:40:11-07	Jeremy Bingham	jbingham@gmail.com
deploy	911c456769628c817340ee77fc8d2b7c1d697782	nodes	goiardi_postgres	Create node table	{goiardi_schema}	{}	{}	2015-07-23 00:27:18.525798-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 10:37:46-07	Jeremy Bingham	jbingham@gmail.com
deploy	faa3571aa479de60f25785e707433b304ba3d2c7	clients	goiardi_postgres	Create client table	{goiardi_schema}	{}	{}	2015-07-23 00:27:18.544958-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 11:05:33-07	Jeremy Bingham	jbingham@gmail.com
deploy	bb82d8869ffca8ba3d03a1502c50dbb3eee7a2e0	users	goiardi_postgres	Create user table	{goiardi_schema}	{}	{}	2015-07-23 00:27:18.564135-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 11:15:02-07	Jeremy Bingham	jbingham@gmail.com
deploy	138bc49d92c0bbb024cea41532a656f2d7f9b072	cookbooks	goiardi_postgres	Create cookbook  table	{goiardi_schema}	{}	{}	2015-07-23 00:27:18.583199-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 11:27:27-07	Jeremy Bingham	jbingham@gmail.com
deploy	f529038064a0259bdecbdab1f9f665e17ddb6136	cookbook_versions	goiardi_postgres	Create cookbook versions table	{cookbooks,goiardi_schema}	{}	{}	2015-07-23 00:27:18.603101-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 11:31:34-07	Jeremy Bingham	jbingham@gmail.com
deploy	85483913f96710c1267c6abacb6568cef9327f15	data_bags	goiardi_postgres	Create cookbook data bags table	{goiardi_schema}	{}	{}	2015-07-23 00:27:18.621987-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 11:42:04-07	Jeremy Bingham	jbingham@gmail.com
deploy	feddf91b62caed36c790988bd29222591980433b	data_bag_items	goiardi_postgres	Create data bag items table	{data_bags,goiardi_schema}	{}	{}	2015-07-23 00:27:18.643787-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 12:02:31-07	Jeremy Bingham	jbingham@gmail.com
deploy	6a4489d9436ba1541d272700b303410cc906b08f	roles	goiardi_postgres	Create roles table	{goiardi_schema}	{}	{}	2015-07-23 00:27:18.663633-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 12:09:28-07	Jeremy Bingham	jbingham@gmail.com
deploy	c4b32778f2911930f583ce15267aade320ac4dcd	sandboxes	goiardi_postgres	Create sandboxes table	{goiardi_schema}	{}	{}	2015-07-23 00:27:18.68814-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 12:14:48-07	Jeremy Bingham	jbingham@gmail.com
deploy	81003655b93b41359804027fc202788aa0ddd9a9	log_infos	goiardi_postgres	Create log_infos table	{clients,users,goiardi_schema}	{}	{}	2015-07-23 00:27:18.711882-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 12:19:10-07	Jeremy Bingham	jbingham@gmail.com
deploy	fce5b7aeed2ad742de1309d7841577cff19475a7	organizations	goiardi_postgres	Create organizations table	{}	{}	{}	2015-07-23 00:27:18.730181-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 12:46:28-07	Jeremy Bingham	jbingham@gmail.com
deploy	f2621482d1c130ea8fee15d09f966685409bf67c	file_checksums	goiardi_postgres	Create file checksums table	{}	{}	{}	2015-07-23 00:27:18.747118-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 12:49:19-07	Jeremy Bingham	jbingham@gmail.com
deploy	db1eb360cd5e6449a468ceb781d82b45dafb5c2d	reports	goiardi_postgres	Create reports table	{}	{}	{}	2015-07-23 00:27:18.767623-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 13:02:49-07	Jeremy Bingham	jbingham@gmail.com
deploy	c8b38382f7e5a18f36c621327f59205aa8aa9849	client_insert_duplicate	goiardi_postgres	Function to emulate insert ... on duplicate update for clients	{clients,goiardi_schema}	{}	{}	2015-07-23 00:27:18.782918-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-29 23:00:04-07	Jeremy Bingham	jbingham@gmail.com
deploy	30774a960a0efb6adfbb1d526b8cdb1a45c7d039	client_rename	goiardi_postgres	Function to rename clients	{clients,goiardi_schema}	{}	{}	2015-07-23 00:27:18.797314-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-30 10:22:50-07	Jeremy Bingham	jbingham@gmail.com
deploy	2d1fdc8128b0632e798df7346e76f122ed5915ec	user_insert_duplicate	goiardi_postgres	Function to emulate insert ... on duplicate update for clients	{users,goiardi_schema}	{}	{}	2015-07-23 00:27:18.812314-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-30 13:07:46-07	Jeremy Bingham	jbingham@gmail.com
deploy	f336c149ab32530c9c6ae4408c11558a635f39a1	user_rename	goiardi_postgres	Function to rename users	{users,goiardi_schema}	{}	{}	2015-07-23 00:27:18.827121-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-30 13:15:45-07	Jeremy Bingham	jbingham@gmail.com
deploy	841a7d554d44f9d0d0b8a1a5a9d0a06ce71a2453	cookbook_insert_update	goiardi_postgres	Cookbook insert/update	{cookbooks,goiardi_schema}	{}	{}	2015-07-23 00:27:18.841947-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-30 23:55:23-07	Jeremy Bingham	jbingham@gmail.com
deploy	085e2f6281914c9fa6521d59fea81f16c106b59f	cookbook_versions_insert_update	goiardi_postgres	Cookbook versions insert/update	{cookbook_versions,goiardi_schema}	{}	{}	2015-07-23 00:27:18.857014-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-30 23:56:05-07	Jeremy Bingham	jbingham@gmail.com
deploy	04bea39d649e4187d9579bd946fd60f760240d10	data_bag_insert_update	goiardi_postgres	Insert/update data bags	{data_bags,goiardi_schema}	{}	{}	2015-07-23 00:27:18.871933-07	Jeremy Bingham	jeremy@goiardi.gl	2014-05-31 23:25:44-07	Jeremy Bingham	jbingham@gmail.com
deploy	092885e8b5d94a9c1834bf309e02dc0f955ff053	environment_insert_update	goiardi_postgres	Insert/update environments	{environments,goiardi_schema}	{}	{}	2015-07-23 00:27:18.887494-07	Jeremy Bingham	jeremy@goiardi.gl	2014-06-01 12:55:34-07	Jeremy Bingham	jbingham@gmail.com
deploy	6d9587fa4275827c93ca9d7e0166ad1887b76cad	file_checksum_insert_ignore	goiardi_postgres	Insert ignore for file checksums	{file_checksums,goiardi_schema}	{}	{}	2015-07-23 00:27:18.903369-07	Jeremy Bingham	jeremy@goiardi.gl	2014-06-01 23:13:48-07	Jeremy Bingham	jbingham@gmail.com
deploy	82a95e5e6cbd8ba51fea33506e1edb2a12e37a92	node_insert_update	goiardi_postgres	Insert/update for nodes	{nodes,goiardi_schema}	{}	{}	2015-07-23 00:27:18.918956-07	Jeremy Bingham	jeremy@goiardi.gl	2014-06-01 23:25:20-07	Jeremy Bingham	jbingham@gmail.com
deploy	d052a8267a6512581e5cab1f89a2456f279727b9	report_insert_update	goiardi_postgres	Insert/update for reports	{reports,goiardi_schema}	{}	{}	2015-07-23 00:27:18.933401-07	Jeremy Bingham	jeremy@goiardi.gl	2014-06-02 10:10:25-07	Jeremy Bingham	jbingham@gmail.com
deploy	acf76029633d50febbec7c4763b7173078eddaf7	role_insert_update	goiardi_postgres	Insert/update for roles	{roles,goiardi_schema}	{}	{}	2015-07-23 00:27:18.950797-07	Jeremy Bingham	jeremy@goiardi.gl	2014-06-02 10:27:32-07	Jeremy Bingham	jbingham@gmail.com
deploy	b8ef36df686397ecb0fe67eb097e84aa0d78ac6b	sandbox_insert_update	goiardi_postgres	Insert/update for sandboxes	{sandboxes,goiardi_schema}	{}	{}	2015-07-23 00:27:18.966848-07	Jeremy Bingham	jeremy@goiardi.gl	2014-06-02 10:34:39-07	Jeremy Bingham	jbingham@gmail.com
deploy	93dbbda50a25da0a586e89ccee8fcfa2ddcb7c64	data_bag_item_insert	goiardi_postgres	Insert for data bag items	{data_bag_items,data_bags,goiardi_schema}	{}	{@v0.6.0}	2015-07-23 00:27:18.984177-07	Jeremy Bingham	jeremy@goiardi.gl	2014-06-02 14:03:22-07	Jeremy Bingham	jbingham@gmail.com
deploy	c80c561c22f6e139165cdb338c7ce6fff8ff268d	bytea_to_json	goiardi_postgres	Change most postgres bytea fields to json, because in this peculiar case json is way faster than gob	{}	{}	{}	2015-07-23 00:27:19.047554-07	Jeremy Bingham	jeremy@goiardi.gl	2014-07-20 02:41:22-07	Jeremy Bingham	jbingham@gmail.com
deploy	9966894e0fc0da573243f6a3c0fc1432a2b63043	joined_cookbkook_version	goiardi_postgres	a convenient view for joined versions for cookbook versions, adapted from erchef's joined_cookbook_version	{}	{}	{@v0.7.0}	2015-07-23 00:27:19.067837-07	Jeremy Bingham	jeremy@goiardi.gl	2014-07-20 03:21:28-07	Jeremy Bingham	jbingham@gmail.com
deploy	163ba4a496b9b4210d335e0e4ea5368a9ea8626c	node_statuses	goiardi_postgres	Create node_status table for node statuses	{nodes}	{}	{}	2015-07-23 00:27:19.08702-07	Jeremy Bingham	jeremy@goiardi.gl	2014-07-10 23:01:54-07	Jeremy Bingham	jeremy@terqa.local
deploy	8bb822f391b499585cfb2fc7248be469b0200682	node_status_insert	goiardi_postgres	insert function for node_statuses	{node_statuses}	{}	{}	2015-07-23 00:27:19.106739-07	Jeremy Bingham	jeremy@goiardi.gl	2014-07-11 00:01:31-07	Jeremy Bingham	jeremy@terqa.local
deploy	7c429aac08527adc774767584201f668408b04a6	add_down_column_nodes	goiardi_postgres	Add is_down column to the nodes table	{nodes}	{}	{}	2015-07-23 00:27:19.135447-07	Jeremy Bingham	jeremy@goiardi.gl	2014-07-15 20:18:05-07	Jeremy Bingham	jbingham@gmail.com
deploy	82bcace325dbdc905eb6e677f800d14a0506a216	shovey	goiardi_postgres	add shovey tables	{}	{}	{}	2015-07-23 00:27:19.16815-07	Jeremy Bingham	jeremy@goiardi.gl	2014-07-15 22:07:12-07	Jeremy Bingham	jeremy@terqa.local
deploy	62046d2fb96bbaedce2406252d312766452551c0	node_latest_statuses	goiardi_postgres	Add a view to easily get nodes by their latest status	{node_statuses}	{}	{}	2015-07-23 00:27:19.184506-07	Jeremy Bingham	jeremy@goiardi.gl	2014-07-26 13:32:02-07	Jeremy Bingham	jbingham@gmail.com
deploy	68f90e1fd2aac6a117d7697626741a02b8d0ebbe	shovey_insert_update	goiardi_postgres	insert/update functions for shovey	{shovey}	{}	{@v0.8.0}	2015-07-23 00:27:19.201804-07	Jeremy Bingham	jeremy@goiardi.gl	2014-08-27 00:46:20-07	Jeremy Bingham	jbingham@gmail.com
deploy	6f7aa2430e01cf33715828f1957d072cd5006d1c	ltree	goiardi_postgres	Add tables for ltree search for postgres	{}	{}	{}	2015-07-23 00:27:19.27561-07	Jeremy Bingham	jeremy@goiardi.gl	2015-04-10 23:21:26-07	Jeremy Bingham	jeremy@goiardi.gl
deploy	e7eb33b00d2fb6302e0c3979e9cac6fb80da377e	ltree_del_col	goiardi_postgres	procedure for deleting search collections	{}	{}	{}	2015-07-23 00:27:19.299282-07	Jeremy Bingham	jeremy@goiardi.gl	2015-04-12 12:33:15-07	Jeremy Bingham	jeremy@goiardi.gl
deploy	f49decbb15053ec5691093568450f642578ca460	ltree_del_item	goiardi_postgres	procedure for deleting search items	{}	{}	{@v0.10.0}	2015-07-23 00:27:19.319497-07	Jeremy Bingham	jeremy@goiardi.gl	2015-04-12 13:03:50-07	Jeremy Bingham	jeremy@goiardi.gl
\.


--
-- Data for Name: projects; Type: TABLE DATA; Schema: sqitch; Owner: -
--

COPY projects (project, uri, created_at, creator_name, creator_email) FROM stdin;
goiardi_postgres	http://ctdk.github.com/goiardi/postgres-support	2015-07-15 12:39:14.141311-07	Jeremy Bingham	jeremy@goiardi.gl
\.


--
-- Data for Name: tags; Type: TABLE DATA; Schema: sqitch; Owner: -
--

COPY tags (tag_id, tag, project, change_id, note, committed_at, committer_name, committer_email, planned_at, planner_name, planner_email) FROM stdin;
fd6ca4c1426a85718d19687591885a2c2a516952	@v0.6.0	goiardi_postgres	93dbbda50a25da0a586e89ccee8fcfa2ddcb7c64	Tag v0.6.0 for release	2015-07-23 00:27:18.982906-07	Jeremy Bingham	jeremy@goiardi.gl	2014-06-27 00:20:56-07	Jeremy Bingham	jbingham@gmail.com
10ec54c07a54a2138c04d471dd6d4a2ce25677b1	@v0.7.0	goiardi_postgres	9966894e0fc0da573243f6a3c0fc1432a2b63043	Tag 0.7.0 postgres schema	2015-07-23 00:27:19.066828-07	Jeremy Bingham	jeremy@goiardi.gl	2014-07-20 23:04:53-07	Jeremy Bingham	jeremy@terqa.local
644417084f02f0e8c6249f6ee0c9bf17b3a037b2	@v0.8.0	goiardi_postgres	68f90e1fd2aac6a117d7697626741a02b8d0ebbe	Tag v0.8.0	2015-07-23 00:27:19.200585-07	Jeremy Bingham	jeremy@goiardi.gl	2014-09-24 21:17:41-07	Jeremy Bingham	jbingham@gmail.com
970e1b9f6fecc093ca76bf75314076afadcdb5fd	@v0.10.0	goiardi_postgres	f49decbb15053ec5691093568450f642578ca460	Tag the 0.10.0 release.	2015-07-23 00:27:19.317997-07	Jeremy Bingham	jeremy@goiardi.gl	2015-07-23 00:21:08-07	Jeremy Bingham	jeremy@goiardi.gl
\.


SET search_path = goiardi, pg_catalog;

--
-- Name: clients_organization_id_name_key; Type: CONSTRAINT; Schema: goiardi; Owner: -; Tablespace: 
--

ALTER TABLE ONLY clients
    ADD CONSTRAINT clients_organization_id_name_key UNIQUE (organization_id, name);


--
-- Name: clients_pkey; Type: CONSTRAINT; Schema: goiardi; Owner: -; Tablespace: 
--

ALTER TABLE ONLY clients
    ADD CONSTRAINT clients_pkey PRIMARY KEY (id);


--
-- Name: cookbook_versions_cookbook_id_major_ver_minor_ver_patch_ver_key; Type: CONSTRAINT; Schema: goiardi; Owner: -; Tablespace: 
--

ALTER TABLE ONLY cookbook_versions
    ADD CONSTRAINT cookbook_versions_cookbook_id_major_ver_minor_ver_patch_ver_key UNIQUE (cookbook_id, major_ver, minor_ver, patch_ver);


--
-- Name: cookbook_versions_pkey; Type: CONSTRAINT; Schema: goiardi; Owner: -; Tablespace: 
--

ALTER TABLE ONLY cookbook_versions
    ADD CONSTRAINT cookbook_versions_pkey PRIMARY KEY (id);


--
-- Name: cookbooks_organization_id_name_key; Type: CONSTRAINT; Schema: goiardi; Owner: -; Tablespace: 
--

ALTER TABLE ONLY cookbooks
    ADD CONSTRAINT cookbooks_organization_id_name_key UNIQUE (organization_id, name);


--
-- Name: cookbooks_pkey; Type: CONSTRAINT; Schema: goiardi; Owner: -; Tablespace: 
--

ALTER TABLE ONLY cookbooks
    ADD CONSTRAINT cookbooks_pkey PRIMARY KEY (id);


--
-- Name: data_bag_items_data_bag_id_name_key; Type: CONSTRAINT; Schema: goiardi; Owner: -; Tablespace: 
--

ALTER TABLE ONLY data_bag_items
    ADD CONSTRAINT data_bag_items_data_bag_id_name_key UNIQUE (data_bag_id, name);


--
-- Name: data_bag_items_data_bag_id_orig_name_key; Type: CONSTRAINT; Schema: goiardi; Owner: -; Tablespace: 
--

ALTER TABLE ONLY data_bag_items
    ADD CONSTRAINT data_bag_items_data_bag_id_orig_name_key UNIQUE (data_bag_id, orig_name);


--
-- Name: data_bag_items_pkey; Type: CONSTRAINT; Schema: goiardi; Owner: -; Tablespace: 
--

ALTER TABLE ONLY data_bag_items
    ADD CONSTRAINT data_bag_items_pkey PRIMARY KEY (id);


--
-- Name: data_bags_organization_id_name_key; Type: CONSTRAINT; Schema: goiardi; Owner: -; Tablespace: 
--

ALTER TABLE ONLY data_bags
    ADD CONSTRAINT data_bags_organization_id_name_key UNIQUE (organization_id, name);


--
-- Name: data_bags_pkey; Type: CONSTRAINT; Schema: goiardi; Owner: -; Tablespace: 
--

ALTER TABLE ONLY data_bags
    ADD CONSTRAINT data_bags_pkey PRIMARY KEY (id);


--
-- Name: environments_organization_id_name_key; Type: CONSTRAINT; Schema: goiardi; Owner: -; Tablespace: 
--

ALTER TABLE ONLY environments
    ADD CONSTRAINT environments_organization_id_name_key UNIQUE (organization_id, name);


--
-- Name: environments_pkey; Type: CONSTRAINT; Schema: goiardi; Owner: -; Tablespace: 
--

ALTER TABLE ONLY environments
    ADD CONSTRAINT environments_pkey PRIMARY KEY (id);


--
-- Name: file_checksums_organization_id_checksum_key; Type: CONSTRAINT; Schema: goiardi; Owner: -; Tablespace: 
--

ALTER TABLE ONLY file_checksums
    ADD CONSTRAINT file_checksums_organization_id_checksum_key UNIQUE (organization_id, checksum);


--
-- Name: file_checksums_pkey; Type: CONSTRAINT; Schema: goiardi; Owner: -; Tablespace: 
--

ALTER TABLE ONLY file_checksums
    ADD CONSTRAINT file_checksums_pkey PRIMARY KEY (id);


--
-- Name: log_infos_pkey; Type: CONSTRAINT; Schema: goiardi; Owner: -; Tablespace: 
--

ALTER TABLE ONLY log_infos
    ADD CONSTRAINT log_infos_pkey PRIMARY KEY (id);


--
-- Name: node_statuses_pkey; Type: CONSTRAINT; Schema: goiardi; Owner: -; Tablespace: 
--

ALTER TABLE ONLY node_statuses
    ADD CONSTRAINT node_statuses_pkey PRIMARY KEY (id);


--
-- Name: nodes_organization_id_name_key; Type: CONSTRAINT; Schema: goiardi; Owner: -; Tablespace: 
--

ALTER TABLE ONLY nodes
    ADD CONSTRAINT nodes_organization_id_name_key UNIQUE (organization_id, name);


--
-- Name: nodes_pkey; Type: CONSTRAINT; Schema: goiardi; Owner: -; Tablespace: 
--

ALTER TABLE ONLY nodes
    ADD CONSTRAINT nodes_pkey PRIMARY KEY (id);


--
-- Name: organizations_name_key; Type: CONSTRAINT; Schema: goiardi; Owner: -; Tablespace: 
--

ALTER TABLE ONLY organizations
    ADD CONSTRAINT organizations_name_key UNIQUE (name);


--
-- Name: organizations_pkey; Type: CONSTRAINT; Schema: goiardi; Owner: -; Tablespace: 
--

ALTER TABLE ONLY organizations
    ADD CONSTRAINT organizations_pkey PRIMARY KEY (id);


--
-- Name: reports_pkey; Type: CONSTRAINT; Schema: goiardi; Owner: -; Tablespace: 
--

ALTER TABLE ONLY reports
    ADD CONSTRAINT reports_pkey PRIMARY KEY (id);


--
-- Name: reports_run_id_key; Type: CONSTRAINT; Schema: goiardi; Owner: -; Tablespace: 
--

ALTER TABLE ONLY reports
    ADD CONSTRAINT reports_run_id_key UNIQUE (run_id);


--
-- Name: roles_organization_id_name_key; Type: CONSTRAINT; Schema: goiardi; Owner: -; Tablespace: 
--

ALTER TABLE ONLY roles
    ADD CONSTRAINT roles_organization_id_name_key UNIQUE (organization_id, name);


--
-- Name: roles_pkey; Type: CONSTRAINT; Schema: goiardi; Owner: -; Tablespace: 
--

ALTER TABLE ONLY roles
    ADD CONSTRAINT roles_pkey PRIMARY KEY (id);


--
-- Name: sandboxes_organization_id_sbox_id_key; Type: CONSTRAINT; Schema: goiardi; Owner: -; Tablespace: 
--

ALTER TABLE ONLY sandboxes
    ADD CONSTRAINT sandboxes_organization_id_sbox_id_key UNIQUE (organization_id, sbox_id);


--
-- Name: sandboxes_pkey; Type: CONSTRAINT; Schema: goiardi; Owner: -; Tablespace: 
--

ALTER TABLE ONLY sandboxes
    ADD CONSTRAINT sandboxes_pkey PRIMARY KEY (id);


--
-- Name: search_collections_organization_id_name_key; Type: CONSTRAINT; Schema: goiardi; Owner: -; Tablespace: 
--

ALTER TABLE ONLY search_collections
    ADD CONSTRAINT search_collections_organization_id_name_key UNIQUE (organization_id, name);


--
-- Name: search_collections_pkey; Type: CONSTRAINT; Schema: goiardi; Owner: -; Tablespace: 
--

ALTER TABLE ONLY search_collections
    ADD CONSTRAINT search_collections_pkey PRIMARY KEY (id);


--
-- Name: search_items_pkey; Type: CONSTRAINT; Schema: goiardi; Owner: -; Tablespace: 
--

ALTER TABLE ONLY search_items
    ADD CONSTRAINT search_items_pkey PRIMARY KEY (id);


--
-- Name: shovey_run_streams_pkey; Type: CONSTRAINT; Schema: goiardi; Owner: -; Tablespace: 
--

ALTER TABLE ONLY shovey_run_streams
    ADD CONSTRAINT shovey_run_streams_pkey PRIMARY KEY (id);


--
-- Name: shovey_run_streams_shovey_run_id_output_type_seq_key; Type: CONSTRAINT; Schema: goiardi; Owner: -; Tablespace: 
--

ALTER TABLE ONLY shovey_run_streams
    ADD CONSTRAINT shovey_run_streams_shovey_run_id_output_type_seq_key UNIQUE (shovey_run_id, output_type, seq);


--
-- Name: shovey_runs_pkey; Type: CONSTRAINT; Schema: goiardi; Owner: -; Tablespace: 
--

ALTER TABLE ONLY shovey_runs
    ADD CONSTRAINT shovey_runs_pkey PRIMARY KEY (id);


--
-- Name: shovey_runs_shovey_id_node_name_key; Type: CONSTRAINT; Schema: goiardi; Owner: -; Tablespace: 
--

ALTER TABLE ONLY shovey_runs
    ADD CONSTRAINT shovey_runs_shovey_id_node_name_key UNIQUE (shovey_id, node_name);


--
-- Name: shoveys_pkey; Type: CONSTRAINT; Schema: goiardi; Owner: -; Tablespace: 
--

ALTER TABLE ONLY shoveys
    ADD CONSTRAINT shoveys_pkey PRIMARY KEY (id);


--
-- Name: shoveys_run_id_key; Type: CONSTRAINT; Schema: goiardi; Owner: -; Tablespace: 
--

ALTER TABLE ONLY shoveys
    ADD CONSTRAINT shoveys_run_id_key UNIQUE (run_id);


--
-- Name: users_email_key; Type: CONSTRAINT; Schema: goiardi; Owner: -; Tablespace: 
--

ALTER TABLE ONLY users
    ADD CONSTRAINT users_email_key UNIQUE (email);


--
-- Name: users_name_key; Type: CONSTRAINT; Schema: goiardi; Owner: -; Tablespace: 
--

ALTER TABLE ONLY users
    ADD CONSTRAINT users_name_key UNIQUE (name);


--
-- Name: users_pkey; Type: CONSTRAINT; Schema: goiardi; Owner: -; Tablespace: 
--

ALTER TABLE ONLY users
    ADD CONSTRAINT users_pkey PRIMARY KEY (id);


SET search_path = sqitch, pg_catalog;

--
-- Name: changes_pkey; Type: CONSTRAINT; Schema: sqitch; Owner: -; Tablespace: 
--

ALTER TABLE ONLY changes
    ADD CONSTRAINT changes_pkey PRIMARY KEY (change_id);


--
-- Name: dependencies_pkey; Type: CONSTRAINT; Schema: sqitch; Owner: -; Tablespace: 
--

ALTER TABLE ONLY dependencies
    ADD CONSTRAINT dependencies_pkey PRIMARY KEY (change_id, dependency);


--
-- Name: events_pkey; Type: CONSTRAINT; Schema: sqitch; Owner: -; Tablespace: 
--

ALTER TABLE ONLY events
    ADD CONSTRAINT events_pkey PRIMARY KEY (change_id, committed_at);


--
-- Name: projects_pkey; Type: CONSTRAINT; Schema: sqitch; Owner: -; Tablespace: 
--

ALTER TABLE ONLY projects
    ADD CONSTRAINT projects_pkey PRIMARY KEY (project);


--
-- Name: projects_uri_key; Type: CONSTRAINT; Schema: sqitch; Owner: -; Tablespace: 
--

ALTER TABLE ONLY projects
    ADD CONSTRAINT projects_uri_key UNIQUE (uri);


--
-- Name: tags_pkey; Type: CONSTRAINT; Schema: sqitch; Owner: -; Tablespace: 
--

ALTER TABLE ONLY tags
    ADD CONSTRAINT tags_pkey PRIMARY KEY (tag_id);


--
-- Name: tags_project_tag_key; Type: CONSTRAINT; Schema: sqitch; Owner: -; Tablespace: 
--

ALTER TABLE ONLY tags
    ADD CONSTRAINT tags_project_tag_key UNIQUE (project, tag);


SET search_path = goiardi, pg_catalog;

--
-- Name: log_info_orgs; Type: INDEX; Schema: goiardi; Owner: -; Tablespace: 
--

CREATE INDEX log_info_orgs ON log_infos USING btree (organization_id);


--
-- Name: log_infos_action; Type: INDEX; Schema: goiardi; Owner: -; Tablespace: 
--

CREATE INDEX log_infos_action ON log_infos USING btree (action);


--
-- Name: log_infos_actor; Type: INDEX; Schema: goiardi; Owner: -; Tablespace: 
--

CREATE INDEX log_infos_actor ON log_infos USING btree (actor_id);


--
-- Name: log_infos_obj; Type: INDEX; Schema: goiardi; Owner: -; Tablespace: 
--

CREATE INDEX log_infos_obj ON log_infos USING btree (object_type, object_name);


--
-- Name: log_infos_time; Type: INDEX; Schema: goiardi; Owner: -; Tablespace: 
--

CREATE INDEX log_infos_time ON log_infos USING btree ("time");


--
-- Name: node_is_down; Type: INDEX; Schema: goiardi; Owner: -; Tablespace: 
--

CREATE INDEX node_is_down ON nodes USING btree (is_down);


--
-- Name: node_status_status; Type: INDEX; Schema: goiardi; Owner: -; Tablespace: 
--

CREATE INDEX node_status_status ON node_statuses USING btree (status);


--
-- Name: node_status_time; Type: INDEX; Schema: goiardi; Owner: -; Tablespace: 
--

CREATE INDEX node_status_time ON node_statuses USING btree (updated_at);


--
-- Name: nodes_chef_env; Type: INDEX; Schema: goiardi; Owner: -; Tablespace: 
--

CREATE INDEX nodes_chef_env ON nodes USING btree (chef_environment);


--
-- Name: report_node_organization; Type: INDEX; Schema: goiardi; Owner: -; Tablespace: 
--

CREATE INDEX report_node_organization ON reports USING btree (node_name, organization_id);


--
-- Name: report_organization_id; Type: INDEX; Schema: goiardi; Owner: -; Tablespace: 
--

CREATE INDEX report_organization_id ON reports USING btree (organization_id);


--
-- Name: search_btree_idx; Type: INDEX; Schema: goiardi; Owner: -; Tablespace: 
--

CREATE INDEX search_btree_idx ON search_items USING btree (path);


--
-- Name: search_col_name; Type: INDEX; Schema: goiardi; Owner: -; Tablespace: 
--

CREATE INDEX search_col_name ON search_collections USING btree (name);


--
-- Name: search_gist_idx; Type: INDEX; Schema: goiardi; Owner: -; Tablespace: 
--

CREATE INDEX search_gist_idx ON search_items USING gist (path);


--
-- Name: search_item_val_trgm; Type: INDEX; Schema: goiardi; Owner: -; Tablespace: 
--

CREATE INDEX search_item_val_trgm ON search_items USING gist (value gist_trgm_ops);


--
-- Name: search_multi_gist_idx; Type: INDEX; Schema: goiardi; Owner: -; Tablespace: 
--

CREATE INDEX search_multi_gist_idx ON search_items USING gist (path, value gist_trgm_ops);


--
-- Name: search_org_col; Type: INDEX; Schema: goiardi; Owner: -; Tablespace: 
--

CREATE INDEX search_org_col ON search_items USING btree (organization_id, search_collection_id);


--
-- Name: search_org_col_name; Type: INDEX; Schema: goiardi; Owner: -; Tablespace: 
--

CREATE INDEX search_org_col_name ON search_items USING btree (organization_id, search_collection_id, item_name);


--
-- Name: search_org_id; Type: INDEX; Schema: goiardi; Owner: -; Tablespace: 
--

CREATE INDEX search_org_id ON search_items USING btree (organization_id);


--
-- Name: search_val; Type: INDEX; Schema: goiardi; Owner: -; Tablespace: 
--

CREATE INDEX search_val ON search_items USING btree (value);


--
-- Name: shovey_organization_id; Type: INDEX; Schema: goiardi; Owner: -; Tablespace: 
--

CREATE INDEX shovey_organization_id ON shoveys USING btree (organization_id);


--
-- Name: shovey_organization_run_id; Type: INDEX; Schema: goiardi; Owner: -; Tablespace: 
--

CREATE INDEX shovey_organization_run_id ON shoveys USING btree (run_id, organization_id);


--
-- Name: shovey_run_node_name; Type: INDEX; Schema: goiardi; Owner: -; Tablespace: 
--

CREATE INDEX shovey_run_node_name ON shovey_runs USING btree (node_name);


--
-- Name: shovey_run_run_id; Type: INDEX; Schema: goiardi; Owner: -; Tablespace: 
--

CREATE INDEX shovey_run_run_id ON shovey_runs USING btree (shovey_uuid);


--
-- Name: shovey_run_status; Type: INDEX; Schema: goiardi; Owner: -; Tablespace: 
--

CREATE INDEX shovey_run_status ON shovey_runs USING btree (status);


--
-- Name: shovey_stream; Type: INDEX; Schema: goiardi; Owner: -; Tablespace: 
--

CREATE INDEX shovey_stream ON shovey_run_streams USING btree (shovey_run_id, output_type);


--
-- Name: shovey_uuid_node; Type: INDEX; Schema: goiardi; Owner: -; Tablespace: 
--

CREATE INDEX shovey_uuid_node ON shovey_runs USING btree (shovey_uuid, node_name);


--
-- Name: shoveys_status; Type: INDEX; Schema: goiardi; Owner: -; Tablespace: 
--

CREATE INDEX shoveys_status ON shoveys USING btree (status);


--
-- Name: insert_ignore; Type: RULE; Schema: goiardi; Owner: -
--

CREATE RULE insert_ignore AS
    ON INSERT TO file_checksums
   WHERE (EXISTS ( SELECT 1
           FROM file_checksums
          WHERE ((file_checksums.organization_id = new.organization_id) AND ((file_checksums.checksum)::text = (new.checksum)::text)))) DO INSTEAD NOTHING;


--
-- Name: cookbook_versions_cookbook_id_fkey; Type: FK CONSTRAINT; Schema: goiardi; Owner: -
--

ALTER TABLE ONLY cookbook_versions
    ADD CONSTRAINT cookbook_versions_cookbook_id_fkey FOREIGN KEY (cookbook_id) REFERENCES cookbooks(id) ON DELETE RESTRICT;


--
-- Name: data_bag_items_data_bag_id_fkey; Type: FK CONSTRAINT; Schema: goiardi; Owner: -
--

ALTER TABLE ONLY data_bag_items
    ADD CONSTRAINT data_bag_items_data_bag_id_fkey FOREIGN KEY (data_bag_id) REFERENCES data_bags(id) ON DELETE RESTRICT;


--
-- Name: node_statuses_node_id_fkey; Type: FK CONSTRAINT; Schema: goiardi; Owner: -
--

ALTER TABLE ONLY node_statuses
    ADD CONSTRAINT node_statuses_node_id_fkey FOREIGN KEY (node_id) REFERENCES nodes(id) ON DELETE CASCADE;


--
-- Name: search_items_search_collection_id_fkey; Type: FK CONSTRAINT; Schema: goiardi; Owner: -
--

ALTER TABLE ONLY search_items
    ADD CONSTRAINT search_items_search_collection_id_fkey FOREIGN KEY (search_collection_id) REFERENCES search_collections(id) ON DELETE RESTRICT;


--
-- Name: shovey_run_streams_shovey_run_id_fkey; Type: FK CONSTRAINT; Schema: goiardi; Owner: -
--

ALTER TABLE ONLY shovey_run_streams
    ADD CONSTRAINT shovey_run_streams_shovey_run_id_fkey FOREIGN KEY (shovey_run_id) REFERENCES shovey_runs(id) ON DELETE RESTRICT;


--
-- Name: shovey_runs_shovey_id_fkey; Type: FK CONSTRAINT; Schema: goiardi; Owner: -
--

ALTER TABLE ONLY shovey_runs
    ADD CONSTRAINT shovey_runs_shovey_id_fkey FOREIGN KEY (shovey_id) REFERENCES shoveys(id) ON DELETE RESTRICT;


SET search_path = sqitch, pg_catalog;

--
-- Name: changes_project_fkey; Type: FK CONSTRAINT; Schema: sqitch; Owner: -
--

ALTER TABLE ONLY changes
    ADD CONSTRAINT changes_project_fkey FOREIGN KEY (project) REFERENCES projects(project) ON UPDATE CASCADE;


--
-- Name: dependencies_change_id_fkey; Type: FK CONSTRAINT; Schema: sqitch; Owner: -
--

ALTER TABLE ONLY dependencies
    ADD CONSTRAINT dependencies_change_id_fkey FOREIGN KEY (change_id) REFERENCES changes(change_id) ON UPDATE CASCADE ON DELETE CASCADE;


--
-- Name: dependencies_dependency_id_fkey; Type: FK CONSTRAINT; Schema: sqitch; Owner: -
--

ALTER TABLE ONLY dependencies
    ADD CONSTRAINT dependencies_dependency_id_fkey FOREIGN KEY (dependency_id) REFERENCES changes(change_id) ON UPDATE CASCADE;


--
-- Name: events_project_fkey; Type: FK CONSTRAINT; Schema: sqitch; Owner: -
--

ALTER TABLE ONLY events
    ADD CONSTRAINT events_project_fkey FOREIGN KEY (project) REFERENCES projects(project) ON UPDATE CASCADE;


--
-- Name: tags_change_id_fkey; Type: FK CONSTRAINT; Schema: sqitch; Owner: -
--

ALTER TABLE ONLY tags
    ADD CONSTRAINT tags_change_id_fkey FOREIGN KEY (change_id) REFERENCES changes(change_id) ON UPDATE CASCADE;


--
-- Name: tags_project_fkey; Type: FK CONSTRAINT; Schema: sqitch; Owner: -
--

ALTER TABLE ONLY tags
    ADD CONSTRAINT tags_project_fkey FOREIGN KEY (project) REFERENCES projects(project) ON UPDATE CASCADE;


--
-- PostgreSQL database dump complete
--

