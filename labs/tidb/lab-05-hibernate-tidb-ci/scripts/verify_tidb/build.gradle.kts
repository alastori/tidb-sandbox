plugins {
    java
    application
}

repositories {
    mavenCentral()
}

dependencies {
    // MySQL Connector/J - same version as Hibernate ORM tests
    implementation("com.mysql:mysql-connector-j:9.1.0")
}

application {
    mainClass.set("VerifyTiDB")
}

java {
    // Use JDK 21 to match Hibernate ORM test environment
    toolchain {
        languageVersion.set(JavaLanguageVersion.of(21))
    }
}

tasks.named<JavaExec>("run") {
    // Suppress Gradle output for cleaner verification output
    standardOutput = System.out
    errorOutput = System.err
}

tasks.register("verify") {
    dependsOn("run")
    description = "Verify TiDB setup for Hibernate ORM tests"
    group = "verification"
}
