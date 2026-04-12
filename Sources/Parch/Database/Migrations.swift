import GRDB

enum ParchMigrations {
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            try db.create(table: "indexed_pdf") { t in
                t.column("content_hash", .text)
                t.column("file_path", .text).notNull().unique()
                t.column("file_size", .integer).notNull()
                t.column("mtime", .double).notNull()
                t.column("conversion_status", .text).notNull().defaults(to: "pending")
                t.column("canonical_path", .text)
                t.column("indexed_at", .double).notNull()
                t.column("converted_at", .double)
                t.column("failure_reason", .text)
            }

            try db.create(
                index: "idx_indexed_pdf_content_hash",
                on: "indexed_pdf",
                columns: ["content_hash"]
            )
            try db.create(
                index: "idx_indexed_pdf_status",
                on: "indexed_pdf",
                columns: ["conversion_status"]
            )
        }

        migrator.registerMigration("v2") { db in
            try db.alter(table: "indexed_pdf") { t in
                t.add(column: "engine", .text)
            }
        }

        return migrator
    }
}
