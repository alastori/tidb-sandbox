package com.pingcap.mvp;

import org.hibernate.Session;
import org.hibernate.SessionFactory;
import org.hibernate.Transaction;
import org.hibernate.boot.registry.StandardServiceRegistryBuilder;
import org.hibernate.cfg.Configuration;
import org.hibernate.service.ServiceRegistry;
import org.junit.jupiter.api.*;

import jakarta.persistence.*;
import java.util.List;
import java.util.Properties;

@Entity(name = "widgets")
class Widget {
  @Id @GeneratedValue(strategy = GenerationType.IDENTITY)
  public Long id;
  @Column(nullable=false)
  public String name;
}

public class ForUpdateAliasTest {
  static SessionFactory sf;

  @BeforeAll
  static void setup() {
    Properties props = new Properties();
    try (var is = ForUpdateAliasTest.class.getClassLoader().getResourceAsStream("hibernate-mysql.properties")) {
      if (is == null) {
        throw new IllegalStateException("hibernate-mysql.properties missing from classpath");
      }
      props.load(is);
    } catch (Exception e) {
      throw new RuntimeException("Failed to load Hibernate properties", e);
    }

    Configuration cfg = new Configuration();
    cfg.addAnnotatedClass(Widget.class);
    cfg.addProperties(props);
    ServiceRegistry sr = new StandardServiceRegistryBuilder().applySettings(cfg.getProperties()).build();
    sf = cfg.buildSessionFactory(sr);
  }

  @AfterAll
  static void close() { if (sf != null) sf.close(); }

  @Test
  void selectForUpdateOfAlias_shouldLock() {
    try (Session s = sf.openSession()) {
      Transaction tx = s.beginTransaction();
      Widget w = new Widget(); w.name = "foo"; s.persist(w);
      tx.commit();
    }

    try (Session s = sf.openSession()) {
      Transaction tx = s.beginTransaction();
      // Use alias in the lock clause to mirror Hibernate’s emitted SQL on MySQLDialect
      List<Widget> rows = s.createQuery("select w from widgets w where w.name = :n", Widget.class)
        .setParameter("n", "foo")
        .setLockMode("w", org.hibernate.LockMode.PESSIMISTIC_WRITE)
        .getResultList();
      Assertions.assertEquals(1, rows.size());
      tx.commit();
    }
  }
}
