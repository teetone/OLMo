UNLOAD (
    WITH s2orc_stats AS (
        SELECT
            id,
            source,
            added,
            created,
            metadata.title AS metadata_title,
            metadata.abstract AS metadata_abstract,
            metadata.year AS metadata_year,
            metadata.count AS metadata_count,
            metadata.sha1 AS metadata_sha1,
            FILTER(
                metadata.paragraphs,
                x -> x.perplexity >= -20
            ) as valid_paragraphs,
            (
                REGEXP_LIKE(
                    metadata.top_frequencies[1].token,
                    '^[A-Za-z][a-z]+$'
                ) AND (
                    (
                        metadata.count > 500 AND
                        (
                            metadata.top_frequencies[1].count / metadata.count
                        ) <= 0.075
                    ) OR (
                        metadata.count <= 500 AND
                        (
                            metadata.top_frequencies[1].count / metadata.count
                        ) <= 0.3
                    )
                )
            ) AS valid_top_word,
            ARRAY_SORT(
                TRANSFORM(
                    MAP_ENTRIES(
                        TRANSFORM_VALUES(
                            -- from table to map
                            MULTIMAP_FROM_ENTRIES(
                                -- from list to table
                                TRANSFORM(
                                    -- extract rows to count
                                    metadata.paragraphs,
                                    x -> ROW(x.language, 1)
                                )
                            ),
                            -- merge counts
                            (k, v) -> REDUCE(v, 0, (s, x) -> s + x, s -> s)
                        )
                    ),
                    x -> CAST(x AS ROW(lang varchar, cnt int))
                ),
                (x, y) -> IF(x.cnt < y.cnt, 1, IF(x.cnt = y.cnt, 0, -1))
            )[1].lang AS metadata_language
        FROM "temp_lucas"."llm_s2orc_v0"
    ),
    filtered_corpus AS (
        SELECT
            id,
            source,
            added,
            created,
            cast(id AS INT) as corpusid,
            metadata_year,
            metadata_sha1,
            (
                metadata_title || CHR(10) || CHR(10) ||
                metadata_abstract || CHR(10) || CHR(10) ||
                ARRAY_JOIN(TRANSFORM(valid_paragraphs, x -> x.text), CHR(10))
            ) as text,
            IF(
                metadata_year < 2022
                OR (
                    metadata_year = 2022 AND
                    date(from_iso8601_timestamp(created)) < date('2022-12-01')
                ),
                'train',
                'valid'
            ) AS split
        FROM s2orc_stats
        WHERE
            metadata_language = 'en'
            AND metadata_count < 50000
            AND metadata_count > 500
            AND valid_top_word
            AND cardinality(valid_paragraphs) >= 5
            AND metadata_title IS NOT NULL
            AND metadata_abstract is not NULL
            AND metadata_year >= 1970
    ),
    filtered_espresso AS (
        SELECT DISTINCT
            pq.corpusid,
            COALESCE(pq.s2FieldsOfStudy, ARRAY[]) as s2FieldsOfStudy,
            COALESCE(pq.fieldsOfStudy, ARRAY[]) as fieldsOfStudy
        from espresso.pq_paper as pq
        RIGHT JOIN filtered_corpus as cr
            ON pq.corpusid = cr.corpusid
    ),
    filtered_corpus_with_fos AS (
        SELECT
            cr.id AS id,
            cr.source AS source,
            cr.added AS added,
            cr.created AS created,
            cr.text AS text,
            cr.split AS split,
            cr.metadata_year AS metadata_year,
            cr.metadata_sha1 AS metadata_sha1,
            pq.s2FieldsOfStudy AS metadata_s2FieldsOfStudy,
            pq.fieldsOfStudy AS metadata_fieldsOfStudy
        from filtered_espresso as pq
        INNER JOIN filtered_corpus as cr
            ON pq.corpusid = cr.corpusid
    )
    SELECT
        id,
        ARRAY_AGG(source)[1] AS source,
        ARRAY_AGG(version)[1] AS version,
        ARRAY_AGG(text)[1] AS text,
        ARRAY_AGG(added)[1] AS added,
        ARRAY_AGG(created)[1] AS created,
        ARRAY_AGG(metadata)[1] AS metadata,
        ARRAY_AGG(split)[1] AS split,
        CAST(id AS INT) % 10 AS part_id
        FROM (
            SELECT
                id,
                source,
                'v3-fos' as version,
                added,
                created,
                text,
                CAST(
                    ROW(metadata_year, metadata_sha1, metadata_s2FieldsOfStudy, metadata_fieldsOfStudy) AS
                    ROW(year BIGINT, sha1 VARCHAR, s2FieldsOfStudy ARRAY<VARCHAR>, extFieldsOfStudy ARRAY<VARCHAR>)
                ) AS metadata,
                split
            FROM filtered_corpus_with_fos
        )
        GROUP BY id
)
TO 's3://ai2-llm/pretraining-data/sources/s2/v3-fos/documents/dataset=s2orc'
WITH (
    format='JSON',
    compression='GZIP',
    partitioned_by = ARRAY['split', 'part_id']
)
