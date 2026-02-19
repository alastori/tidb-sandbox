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
    mainClass.set("VarcharJdbcTest")
}

java {
    toolchain {
        languageVersion.set(JavaLanguageVersion.of(21))
    }
}
