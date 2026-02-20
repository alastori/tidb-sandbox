plugins {
    java
    application
}

repositories {
    mavenCentral()
}

dependencies {
    implementation("com.mysql:mysql-connector-j:9.1.0")
}

application {
    mainClass.set(System.getProperty("mainClass") ?: "VarcharJdbcTest")
}

tasks.register<JavaExec>("runPartitioned") {
    mainClass.set("VarcharPartitionedJdbcTest")
    classpath = sourceSets["main"].runtimeClasspath
}

tasks.named<JavaExec>("run") {
    // Allow override: ./gradlew run -DmainClass=VarcharPartitionedJdbcTest
}

java {
    toolchain {
        languageVersion.set(JavaLanguageVersion.of(21))
    }
}
